# frozen_string_literal: true

require "spec_helper"
require "phronomy/integrations/ordered_event_delivery"

RSpec.describe "Error API boundaries" do
  describe "tracing lifetime" do
    let(:tracer) { double("tracer") }
    let(:span) { Object.new }
    before { allow(tracer).to receive(:start_span).and_return(span) }

    it "does not finish a span whose start failed" do
      error = IOError.new("start")
      allow(tracer).to receive(:start_span).and_raise(error)
      expect(tracer).not_to receive(:finish_span)
      expect { Phronomy::Tracing::Base.trace_with(tracer, "op") { raise "not called" } }
        .to raise_error { |actual| expect(actual).to equal(error) }
    end

    it "finishes once when successful work is followed by a finish failure" do
      error = IOError.new("finish")
      expect(tracer).to receive(:finish_span).once.with(span, output: "done", usage: nil).and_raise(error)
      expect { Phronomy::Tracing::Base.trace_with(tracer, "op") { ["done", nil] } }
        .to raise_error { |actual| expect(actual).to equal(error) }
    end

    it "retains the primary error when finish and reporting both fail" do
      primary = ArgumentError.new("business")
      secondary = IOError.new("finish")
      expect(tracer).to receive(:finish_span).once.with(span, error: primary).and_raise(secondary)
      logger = double("logger")
      allow(Phronomy::RuntimeSettings.current).to receive(:logger).and_return(logger)
      expect(logger).to receive(:warn).and_raise(IOError.new("logger"))
      expect { Phronomy::Tracing::Base.trace_with(tracer, "op") { raise primary } }
        .to raise_error { |actual| expect(actual).to equal(primary) }
    end

    it "keeps Context policy failures and does not export policy output" do
      input = double("input", agent_id: "a", execution_id: "e", call_sequence: 1,
        instruction: [], knowledge: [], tools: [], conversation: [])
      policy = ->(_) { "private plan" }
      assembly = Phronomy::Context::Assembly.new(tracer: tracer)
      expect(tracer).to receive(:finish_span).once.with(span)
      expect(assembly.send(:invoke_policy, policy, input)).to eq("private plan")
      primary = RuntimeError.new("policy")
      expect(tracer).to receive(:finish_span).once.with(span, error: primary).and_raise(IOError.new("finish"))
      expect { assembly.send(:invoke_policy, ->(_) { raise primary }, input) }
        .to raise_error { |actual| expect(actual).to equal(primary) }
    end
  end

  describe "Agent target absence" do
    let(:store) { Phronomy::PersistenceComposition.in_memory.agent }
    let(:agent_class) { Class.new(Phronomy::Agent::Base) { agent_definition id: "error-api", version: 1 } }

    it "specializes the old persistence rescue only for the requested root" do
      expect { agent_class.load("absent", persistence: store) }.to raise_error(Phronomy::AgentNotFoundError) { |error|
        expect(error).to be_a(Phronomy::Persistence::NotFoundError)
        expect(error.agent_id).to eq("absent")
        expect(error.agent_id).to be_frozen
        expect(error.code).to eq("agent.not_found")
        expect(error.cause).to be_a(Phronomy::Persistence::NotFoundError)
      }
    end

    it "does not translate a missing referenced journal into Agent absence" do
      agent = agent_class.create(agent_id: "present", persistence: store)
      Phronomy.reset_runtime!
      missing = Phronomy::Persistence::NotFoundError.new("journal missing")
      allow(store).to receive(:transaction).and_wrap_original do |original, &block|
        original.call do |tx|
          allow(tx.journals).to receive(:read).and_raise(missing)
          block.call(tx)
        end
      end
      expect { agent_class.load(agent.agent_id, persistence: store) }
        .to raise_error { |actual| expect(actual).to equal(missing) }
      expect(store.agents.load("present").agent_id).to eq("present")
    end
  end

  describe "content representation" do
    let(:contents) { Phronomy::PersistenceComposition.in_memory.agent.contents }

    it "classifies JSON and encoding failures at the content boundary" do
      reference = contents.put_text("{")
      expect { contents.fetch_json(reference) }.to raise_error(Phronomy::ContentStore::IntegrityError) { |error|
        expect(error.code).to eq("content.invalid_json")
        expect(error.cause).to be_a(JSON::ParserError)
      }
      invalid = contents.put("\xff".b, canonicalization_version: 1)
      expect { contents.fetch_text(invalid) }.to raise_error(Phronomy::ContentStore::IntegrityError) { |error|
        expect(error.code).to eq("content.invalid_encoding")
      }
    end

    it "does not translate missing content or backend failures into invalid JSON" do
      expect { contents.fetch_json("sha256:missing") }.to raise_error(Phronomy::Persistence::NotFoundError)
      transport = IOError.new("offline")
      allow(contents).to receive(:fetch).and_raise(transport)
      expect { contents.fetch_json("any") }.to raise_error { |actual| expect(actual).to equal(transport) }
      unusual = JSON::ParserError.new("backend bug")
      allow(contents).to receive(:fetch).and_raise(unusual)
      expect { contents.fetch_json("any") }.to raise_error { |actual| expect(actual).to equal(unusual) }
    end
  end

  describe "Embeddings provider errors" do
    let(:adapter) { Phronomy::Embeddings::RubyLLMEmbeddings.new }
    [
      [RubyLLM::UnauthorizedError, Phronomy::Embeddings::AuthenticationError, "embeddings.authentication_failed"],
      [RubyLLM::ForbiddenError, Phronomy::Embeddings::AuthenticationError, "embeddings.authentication_failed"],
      [RubyLLM::RateLimitError, Phronomy::Embeddings::RateLimitError, "embeddings.rate_limited"],
      [RubyLLM::Error, Phronomy::Embeddings::TransportError, nil]
    ].each do |source_type, target_type, code|
      it "preserves the #{source_type} cause and existing TransportError rescue" do
        source = source_type.new("provider rejected")
        allow(RubyLLM).to receive(:embed).and_raise(source)
        expect { adapter.embed("input") }.to raise_error(target_type) { |error|
          expect(error).to be_a(Phronomy::Embeddings::TransportError)
          expect(error.cause).to equal(source)
          expect(error.code).to eq(code)
        }
      end
    end

    it "does not reinterpret cancellation or unknown implementation errors" do
      [Phronomy::CancellationError.new("cancel"), NoMethodError.new("bug"), IOError.new("io")].each do |source|
        allow(RubyLLM).to receive(:embed).and_raise(source)
        expect { adapter.embed("input") }.to raise_error { |error| expect(error).to equal(source) }
      end
    end
  end

  it "keeps TaskResult settled and delivers remaining observers when callback and logger fail" do
    task = Phronomy::TaskResult.deferred
    received = []
    logger = double("logger")
    allow(Phronomy::RuntimeSettings.current).to receive(:logger).and_return(logger)
    allow(logger).to receive(:error).and_raise(IOError.new("logging failed"))
    task.on_complete { raise "observer failed" }
    task.on_complete { |value, error| received << [value, error] }
    expect { task.complete("done") }.not_to raise_error
    expect(received).to eq([["done", nil]])
    expect(task.wait_result).to eq("done")
    expect { task.on_complete { raise "late observer" } }.not_to raise_error
    transformed = task.map { raise ArgumentError, "transform failed" }
    expect { transformed.wait_result }.to raise_error(ArgumentError, "transform failed")
    expect(task.wait_result).to eq("done")
  end

  it "makes closed event delivery a framework error with a stable reason" do
    delivery = Phronomy::Integrations::OrderedEventDelivery.new { |_| }
    delivery.close_and_wait
    expect { delivery.publish(type: "late") }.to raise_error(Phronomy::Error) { |error|
      expect(error).to be_a(Phronomy::Integrations::OrderedEventDelivery::ClosedError)
      expect(error.code).to eq("delivery.closed")
    }
  end
end
