# frozen_string_literal: true

require "spec_helper"

RSpec.describe "LLM operation contract" do
  let(:request) { Phronomy::LLMAdapter::Request.new(message: "hello") }

  it "requires protected synchronous hooks and rejects SDK-shaped values" do
    base = Phronomy::LLMAdapter::Base.new
    expect(base.public_methods(false)).to contain_exactly(:complete, :stream, :identity, :input_budget)
    expect { base.complete(request) }.to raise_error(NotImplementedError)
    expect { base.stream(request) { |_| } }.to raise_error(NotImplementedError)
    expect { base.complete(Object.new) }.to raise_error(ArgumentError, /Request/)
    broken = Class.new(Phronomy::LLMAdapter::Base) do
      protected

      def perform_complete(request, cancellation_token:) = Object.new

      def perform_stream(request, cancellation_token:)
        yield "untyped"
      end
    end.new
    expect { broken.complete(request) }.to raise_error(Phronomy::LLMAdapter::InvalidResultError, /Response/)
    expect { broken.stream(request) { |_| } }.to raise_error(Phronomy::LLMAdapter::InvalidResultError, /StreamChunk/)
  end

  it "checks pre-cancellation before invoking the backend" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    base = Phronomy::LLMAdapter::Base.new
    expect(base).not_to receive(:perform_complete)
    expect { base.complete(request, cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
  end

  %i[invoke_async stream_async].each do |entry|
    it "runs a minimal independent backend, Tool continuation and #{entry} through Agent" do
      requests, workers, events, approved_arguments = [], [], [], []
      adapter = Class.new(Phronomy::LLMAdapter::Base) do
        define_method(:initialize) { |requests, workers| @requests, @workers = requests, workers }
        protected

        define_method(:perform_complete) do |request, cancellation_token:|
          @requests << request
          @workers << Thread.current
          if request.messages.any? { |message| message.role == :tool }
            Phronomy::LLMAdapter::Response.new(content: "done")
          else
            Phronomy::LLMAdapter::Response.new(tool_calls: [
              Phronomy::Tool::CallRequest.new(id: "call-1", name: "double_value", arguments: {"n" => "2"})
            ])
          end
        end
        define_method(:perform_stream) do |request, cancellation_token:, &sink|
          sink.call(Phronomy::LLMAdapter::StreamChunk.new(content: "part"))
          perform_complete(request, cancellation_token: cancellation_token)
        end
      end.new(requests, workers)
      tool = Class.new(Phronomy::Tool::Base) do
        tool_name "double_value"
        description "Double an integer"
        on_schema_error :coerce
        parameters({"type" => "object", "properties" => {"n" => {"type" => "integer"}}, "required" => ["n"]})
        approval_facts { |arguments, _|
          approved_arguments << arguments
          {}
        }
        def execute(n:) = (n * 2).to_s
      end
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "independent-#{entry}", version: 1
        model "independent"
        tools tool => nil
      end
      Phronomy.configure { |config| config.llm_adapter = adapter }
      expect(RubyLLM).not_to receive(:chat)
      runtime = Phronomy::Runtime.instance
      agent = agent_class.new(on_event: ->(event) { events << [event, Thread.current, runtime.event_loop_current?] })
      expect(agent.public_send(entry, "hello").wait_result(timeout: 5)[:output]).to eq("done")
      expect(approved_arguments).to eq([{n: 2}])
      expect(approved_arguments.first).to be_frozen
      expect(requests.size).to eq(2)
      expect(requests).to all(be_frozen)
      expect(requests.last.messages.find { |message| message.role == :tool }.content).to eq("4")
      expect(requests.first.tools.first.fetch("name")).to eq("double_value")
      expect(workers & events.map { |_, thread, _| thread }).to be_empty
      expect(events.map(&:last)).to all(be true)
      expect(events.any? { |event, _, _| event.type == :token }).to eq(entry == :stream_async)
    end
  end
end
