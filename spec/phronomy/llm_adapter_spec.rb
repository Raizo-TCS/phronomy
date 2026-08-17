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

    describe "#complete_async" do
      it "submits synchronous complete to OffloadPool and returns a Task" do
        pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 10)
        concrete = Class.new(described_class) do
          def complete(_chat, message, config: {})
            "response:#{message}"
          end
        end.new

        task = concrete.complete_async(double, "ping", config: {}, pool: pool)
        expect(task).to be_a(Phronomy::Task)
        expect(task.wait_result).to eq("response:ping")
      ensure
        pool&.shutdown
      end
    end

    describe "#stream_async" do
      it "submits synchronous stream to OffloadPool and returns a Task" do
        pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 10)
        received_chunks = []
        concrete = Class.new(described_class) do
          def stream(_chat, _message, config: {}, &block)
            block.call("chunk1")
            block.call("chunk2")
            "done"
          end
        end.new

        task = concrete.stream_async(double, "ping", config: {}, pool: pool) do |chunk|
          received_chunks << chunk
        end
        expect(task).to be_a(Phronomy::Task)
        expect(task.wait_result).to eq("done")
        expect(received_chunks).to eq(%w[chunk1 chunk2])
      ensure
        pool&.shutdown
      end

      it "checks cancellation before delivering each chunk" do
        pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 10)
        token = Phronomy::Concurrency::CancellationToken.new
        received = []
        concrete = Class.new(described_class) do
          def stream(_chat, _message, config: {}, &block)
            block.call("c1")
            block.call("c2")
            "done"
          end
        end.new

        task = concrete.stream_async(
          double,
          "ping",
          config: {cancellation_token: token},
          pool: pool
        ) do |chunk|
          received << chunk
          token.cancel! if chunk == "c1"
        end

        expect { task.wait_result }.to raise_error(Phronomy::CancellationError)
        expect(task.status).to eq(:cancelled)
        expect(received).to eq(["c1"])
      ensure
        pool&.shutdown
      end
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
        cached: 0,
        cache_creation: 0,
        to_h: {"input" => 10, "output" => 20, "cached" => 0, "cache_creation" => 0}
      )
      double("response", content: "adapter response", tokens: tokens)
    end

    let(:fake_adapter) do
      pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 10)
      adapter = instance_double(Phronomy::LLMAdapter::RubyLLM)
      task = pool.submit { fake_response }
      allow(adapter).to receive(:complete_async).and_return(task)
      [adapter, pool]
    end

    it "calls adapter.complete_async instead of chat.ask directly" do
      adapter, pool = fake_adapter
      Phronomy.configure { |config| config.llm_adapter = adapter }

      chat = double("chat", messages: [], on_tool_call: nil, on_tool_result: nil)
      allow_any_instance_of(agent_class).to receive(:build_chat).and_return(chat)
      allow_any_instance_of(agent_class).to receive(:apply_instructions)
      allow_any_instance_of(agent_class)
        .to receive(:run_before_llm_input_hooks)
        .and_return(Phronomy::Agent::LLMInputPatch.empty)
      allow_any_instance_of(agent_class).to receive(:check_cancellation!)
      allow(chat).to receive(:before_tool_call)
      allow(chat).to receive(:respond_to?) do |method_name, *|
        method_name.to_sym == :before_tool_call
      end

      result = agent_class.new.invoke("hello")
      expect(result[:output]).to eq("adapter response")
      expect(adapter).to have_received(:complete_async)
    ensure
      Phronomy.configure { |config| config.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new }
      pool&.shutdown
    end
  end
end
