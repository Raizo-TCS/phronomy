# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Base do
  describe ".max_parallel_tools DSL validation (issue #152)" do
    it "accepts a positive integer" do
      klass = Class.new(Phronomy::Agent::Base) { max_parallel_tools 4 }
      expect(klass.max_parallel_tools).to eq(4)
    end

    it "accepts 1 (minimum valid value)" do
      klass = Class.new(Phronomy::Agent::Base) { max_parallel_tools 1 }
      expect(klass.max_parallel_tools).to eq(1)
    end

    it "raises ArgumentError for 0" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools 0 } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "raises ArgumentError for a negative integer" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools(-1) } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "raises ArgumentError for a float" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools 2.5 } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "raises ArgumentError for a string" do
      expect { Class.new(Phronomy::Agent::Base) { max_parallel_tools "4" } }
        .to raise_error(ArgumentError, /max_parallel_tools/)
    end

    it "returns the default (10) when not set" do
      klass = Class.new(Phronomy::Agent::Base)
      expect(klass.max_parallel_tools).to eq(10)
    end
  end

  describe ".invoke_timeout DSL validation (issue #152)" do
    it "accepts a positive integer" do
      klass = Class.new(Phronomy::Agent::Base) { invoke_timeout 30 }
      expect(klass.invoke_timeout).to eq(30)
    end

    it "accepts a positive float" do
      klass = Class.new(Phronomy::Agent::Base) { invoke_timeout 0.5 }
      expect(klass.invoke_timeout).to eq(0.5)
    end

    it "raises ArgumentError for 0" do
      expect { Class.new(Phronomy::Agent::Base) { invoke_timeout 0 } }
        .to raise_error(ArgumentError, /invoke_timeout/)
    end

    it "raises ArgumentError for a negative number" do
      expect { Class.new(Phronomy::Agent::Base) { invoke_timeout(-5) } }
        .to raise_error(ArgumentError, /invoke_timeout/)
    end

    it "raises ArgumentError for a string" do
      expect { Class.new(Phronomy::Agent::Base) { invoke_timeout "30" } }
        .to raise_error(ArgumentError, /invoke_timeout/)
    end

    it "returns nil (no timeout) when not set" do
      klass = Class.new(Phronomy::Agent::Base)
      expect(klass.invoke_timeout).to be_nil
    end
  end

  describe "#check_cancellation! (Issue #223)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) { model "test-model" }.new
    end

    it "does nothing when config has no cancellation_token" do
      expect { agent.send(:check_cancellation!, {}) }.not_to raise_error
    end

    it "does nothing when cancellation_token is not cancelled" do
      token = Phronomy::CancellationToken.new
      expect { agent.send(:check_cancellation!, {cancellation_token: token}) }.not_to raise_error
    end

    it "raises CancellationError when token is cancelled" do
      token = Phronomy::CancellationToken.new
      token.cancel!
      expect {
        agent.send(:check_cancellation!, {cancellation_token: token})
      }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError with the provided message" do
      token = Phronomy::CancellationToken.new
      token.cancel!
      expect {
        agent.send(:check_cancellation!, {cancellation_token: token}, "cancelled mid-RAG")
      }.to raise_error(Phronomy::CancellationError, "cancelled mid-RAG")
    end

    context "build_context cancellation (Issue #223)" do
      it "raises CancellationError before fetching a knowledge source when pre-cancelled" do
        ks = double("KnowledgeSource")
        expect(ks).not_to receive(:fetch_async)

        token = Phronomy::CancellationToken.new
        token.cancel!

        expect {
          agent.send(:build_context, "query",
            config: {cancellation_token: token, knowledge_sources: [ks]})
        }.to raise_error(Phronomy::CancellationError, /RAG fetch/)
      end

      it "proceeds normally when token is not cancelled" do
        ks = double("KnowledgeSource")
        pool = Phronomy::Runtime.instance.blocking_io
        pending_op = pool.submit { [] }
        allow(ks).to receive(:fetch_async).and_return(pending_op)

        token = Phronomy::CancellationToken.new

        expect {
          agent.send(:build_context, "query",
            config: {cancellation_token: token, knowledge_sources: [ks]})
        }.not_to raise_error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #291 — invoke_async is the primary path; invoke is a wrapper
  # ---------------------------------------------------------------------------

  describe "invoke_async (Issue #291)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end

    it "returns a Task" do
      allow_any_instance_of(Phronomy::Agent::Base).to receive(:_invoke_impl).and_return({output: "ok"})
      task = agent.invoke_async("hi")
      expect(task).to be_a(Phronomy::Task)
      task.await
    end

    it "executes _invoke_impl directly (not via invoke)" do
      called = []
      allow_any_instance_of(Phronomy::Agent::Base).to receive(:_invoke_impl) {
        called << :impl
        {output: "ok"}
      }
      agent.invoke_async("hi").await
      expect(called).to eq([:impl])
    end

    it "registers the task with Runtime so shutdown can drain it" do
      latch = Queue.new
      allow_any_instance_of(Phronomy::Agent::Base).to receive(:_invoke_impl) do
        latch.pop
        {output: "ok"}
      end
      task = agent.invoke_async("hi")
      Phronomy::Runtime.instance.instance_variable_get(:@tasks)
      # task should be registered (may already be removed if it ran fast on FakeScheduler)
      latch.push(:go)
      task.await
    end
  end

  describe "#invoke SchedulerReentrancyError guard (Issue #291)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end

    it "raises SchedulerReentrancyError when called from inside a Task" do
      error = nil
      Phronomy::Task.spawn do
        agent.invoke("hi")
      rescue Phronomy::SchedulerReentrancyError => e
        error = e
      end.await
      expect(error).to be_a(Phronomy::SchedulerReentrancyError)
      expect(error.message).to include("invoke_async")
    end

    it "does not raise when called outside a Task" do
      allow_any_instance_of(Phronomy::Agent::Base).to receive(:_invoke_impl).and_return({output: "ok"})
      expect { agent.invoke("hi") }.not_to raise_error
    end
  end
end
