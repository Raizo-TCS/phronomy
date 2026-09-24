# frozen_string_literal: true

require "spec_helper"

RSpec.describe "LLMAdapter abstraction" do
  describe Phronomy::LLMAdapter::Base do
    subject(:adapter) { described_class.new }

    describe "#complete" do
      it "raises NotImplementedError" do
        expect { adapter.complete(double, "hello") }.to raise_error(NotImplementedError)
      end
    end

    describe "#stream" do
      it "raises NotImplementedError" do
        expect { adapter.stream(double, "hello") }.to raise_error(NotImplementedError)
      end
    end

    it "exposes only the synchronous implementer contract" do
      expect(described_class.public_instance_methods(false)).to contain_exactly(:complete, :stream)
      expect(adapter).not_to respond_to(:complete_async, :stream_async)
    end
  end

  describe Phronomy::LLMAdapter::RubyLLM do
    subject(:adapter) { described_class.new }

    let(:chat) { double("chat") }
    let(:response) { double("response", content: "hello", tokens: nil) }

    describe "#complete" do
      it "delegates to chat.ask(message)" do
        expect(chat).to receive(:ask).with("ping").and_return(response)
        expect(adapter.complete(chat, "ping")).to eq(response)
      end

      it "delegates a nil continuation message to chat.complete" do
        expect(chat).to receive(:complete).and_return(response)
        expect(adapter.complete(chat, nil)).to eq(response)
      end
    end

    describe "#stream" do
      it "delegates to chat.ask(message) with a block" do
        chunks = []
        expect(chat).to receive(:ask).with("ping") do |_msg, &block|
          block&.call("token1")
          response
        end
        result = adapter.stream(chat, "ping") { |chunk| chunks << chunk }
        expect(result).to eq(response)
        expect(chunks).to eq(["token1"])
      end

      it "delegates a nil continuation message to chat.complete with the block" do
        chunks = []
        expect(chat).to receive(:complete) do |&block|
          block&.call("token1")
          response
        end
        result = adapter.stream(chat, nil) { |chunk| chunks << chunk }
        expect(result).to eq(response)
        expect(chunks).to eq(["token1"])
      end
    end
  end

  describe "Configuration#llm_adapter" do
    it "defaults to an instance of Phronomy::LLMAdapter::RubyLLM" do
      config = Phronomy::Configuration.new
      expect(config.llm_adapter).to be_a(Phronomy::LLMAdapter::RubyLLM)
    end

    it "can be replaced with a custom Base implementation" do
      custom = Class.new(Phronomy::LLMAdapter::Base) do
        def complete(_chat, _message, config: {}) = :ok
        def stream(_chat, _message, config: {}) = :ok
      end.new

      Phronomy.configure { |config| config.llm_adapter = custom }
      expect(Phronomy.configuration.llm_adapter).to equal(custom)
    ensure
      Phronomy.configure { |config| config.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new }
    end
  end

  describe "Agent::Base routes LLM calls through LLMAdapter" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-116", version: 1
        model "test-model"
        instructions "You are a test agent."
      end
    end

    let(:fake_response) do
      tokens = double(
        "tokens",
        input: 10,
        output: 20,
        cache_read: 0,
        cache_write: 0,
        to_h: {"input" => 10, "output" => 20, "cached" => 0, "cache_creation" => 0}
      )
      double("response", content: "adapter response", tokens: tokens)
    end

    let(:fake_adapter) do
      instance_double(Phronomy::LLMAdapter::RubyLLM, complete: fake_response)
    end

    before do
      Phronomy.configure { |config| config.llm_adapter = fake_adapter }
      chat = double("chat", messages: [], on_tool_call: nil, on_tool_result: nil)
      allow_any_instance_of(agent_class).to receive(:build_chat).and_return(chat)
      allow_any_instance_of(agent_class).to receive(:apply_instructions)
      allow_any_instance_of(agent_class)
        .to receive(:run_before_llm_input_hooks)
        .and_return(Phronomy::Agent::LLMInputPatch.empty)
      allow_any_instance_of(agent_class).to receive(:check_cancellation!)
      allow(chat).to receive(:after_message)
      allow(chat).to receive(:respond_to?) do |method_name, *|
        method_name.to_sym == :after_message
      end
    end

    it "executes a synchronous-only adapter through the framework client" do
      result = agent_class.new.invoke("hello")
      expect(result[:output]).to eq("adapter response")
      expect(fake_adapter).to have_received(:complete)
    end

    it "keeps adapter streaming on a worker and application callbacks on EventLoop" do
      worker_threads = []
      callback_threads = []
      callback_on_loop = []
      events = []
      allow(fake_adapter).to receive(:stream) do |_chat, _message, **_config, &sink|
        worker_threads << Thread.current
        sink.call(double("chunk", content: "part"))
        fake_response
      end
      runtime = Phronomy::Runtime.instance
      agent = agent_class.new(on_event: ->(event) {
        callback_threads << Thread.current
        callback_on_loop << runtime.event_loop_current?
        events << event
      })

      result = agent.stream_async("hello").wait_result(timeout: 5)
      expect(result[:output]).to eq("adapter response")
      expect(fake_adapter).to have_received(:stream)
      expect(worker_threads).not_to be_empty
      expect(callback_threads).not_to be_empty
      expect(worker_threads & callback_threads).to be_empty
      expect(callback_on_loop).to all(be true)
      expect(events.any? { |event| event.type == :token }).to be true
    end
  end
end
