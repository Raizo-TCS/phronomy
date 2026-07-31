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
      it "submits the blocking complete call to the provided pool and returns a PendingOperation" do
        pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 10)
        concrete = Class.new(described_class) do
          def complete(chat, message, config: {})
            "response:#{message}"
          end
        end.new

        op = concrete.complete_async(double, "ping", config: {}, pool: pool)
        expect(op).to respond_to(:blocking_wait)
        expect(op.wait_result).to eq("response:ping")
      ensure
        pool.shutdown
      end
    end

    describe "#stream_async" do
      it "submits the blocking stream call to the provided pool and returns a PendingOperation" do
        pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 10)
        received_chunks = []
        concrete = Class.new(described_class) do
          def stream(chat, message, config: {}, &block)
            block.call("chunk1")
            block.call("chunk2")
            "done"
          end
        end.new

        op = concrete.stream_async(double, "ping", config: {}, pool: pool) do |chunk|
          received_chunks << chunk
        end
        result = op.wait_result

        expect(result).to eq("done")
        expect(received_chunks).to eq(%w[chunk1 chunk2])
      ensure
        pool.shutdown
      end
    end

    describe "#stream_async cancellation" do
      it "checks the cancellation token before delivering each chunk" do
        pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 10)
        token = Phronomy::Concurrency::CancellationToken.new
        received = []
        concrete = Class.new(described_class) do
          def stream(chat, message, config: {}, &blk)
            blk.call("c1")
            blk.call("c2")
            "done"
          end
        end.new

        pending = concrete.stream_async(
          double,
          "ping",
          config: {cancellation_token: token},
          pool: pool
        ) do |chunk|
          received << chunk
          token.cancel! if chunk == "c1"
        end

        expect { pending.wait_result }.to raise_error(Phronomy::CancellationError)
        expect(received).to eq(["c1"])
      ensure
        pool.shutdown
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
    end

    describe "#stream" do
      it "delegates to chat.ask(message) with a block" do
        chunks = []
        expect(chat).to receive(:ask).with("ping") do |_msg, &blk|
          blk&.call("token1")
          response
        end
        result = adapter.stream(chat, "ping") { |c| chunks << c }
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

    it "can be replaced with a custom adapter" do
      custom = Phronomy::LLMAdapter::Base.new
      Phronomy.configure { |c| c.llm_adapter = custom }
      expect(Phronomy.configuration.llm_adapter).to equal(custom)
    ensure
      Phronomy.configure { |c| c.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new }
    end
  end

  describe "Agent::Base routes LLM calls through LLMAdapter" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        model "test-model"
        instructions "You are a test agent."
      end
    end

    let(:fake_response) do
      tokens = double("tokens",
        input: 10, output: 20, cached: 0, cache_creation: 0)
      double("response", content: "adapter response", tokens: tokens)
    end

    let(:fake_adapter) do
      pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 10)
      adapter = instance_double(Phronomy::LLMAdapter::RubyLLM)
      pending_op = pool.submit { fake_response }
      allow(adapter).to receive(:complete_async).and_return(pending_op)
      [adapter, pool]
    end

    it "calls adapter.complete_async instead of chat.ask directly" do
      adapter, pool = fake_adapter
      Phronomy.configure { |c| c.llm_adapter = adapter }

      # Stub build_chat to avoid real RubyLLM setup
      chat = double("chat",
        messages: [],
        on_tool_call: nil,
        on_tool_result: nil)
      allow_any_instance_of(agent_class).to receive(:build_chat).and_return(chat)
      allow_any_instance_of(agent_class).to receive(:build_context).and_return(
        {system: nil, messages: [], tool_classes: []}
      )
      allow_any_instance_of(agent_class).to receive(:apply_instructions)
      allow_any_instance_of(agent_class).to receive(:run_before_completion_hooks!)
      allow_any_instance_of(agent_class).to receive(:check_cancellation!)
      # chat.respond_to? is called for both :cancellation_token= and :on_tool_call_batch
      allow(chat).to receive(:respond_to?).and_return(false)

      result = agent_class.new.invoke("hello")
      expect(result[:output]).to eq("adapter response")
      expect(adapter).to have_received(:complete_async)
    ensure
      Phronomy.configure { |c| c.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new }
      pool.shutdown
    end
  end
end
