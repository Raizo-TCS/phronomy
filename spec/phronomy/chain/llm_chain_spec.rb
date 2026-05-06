# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Chain::LLMChain do
  # Mock of RubyLLM::Chat
  let(:fake_message) { double("Message", content: "Hello from LLM") }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:ask).and_return(fake_message)
    allow(dbl).to receive(:last_message).and_return(fake_message)
    dbl
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(fake_chat)
  end

  describe "#invoke" do
    subject(:chain) { described_class.new }

    context "with a String input" do
      it "passes the string to ask and returns the response text" do
        result = chain.invoke("What is Ruby?")
        expect(fake_chat).to have_received(:ask).with("What is Ruby?")
        expect(result).to eq("Hello from LLM")
      end
    end

    context "with Hash input (user key)" do
      it "passes the user message to ask" do
        chain.invoke({user: "Tell me about Ruby"})
        expect(fake_chat).to have_received(:ask).with("Tell me about Ruby")
      end
    end

    context "with Hash input (system + user keys)" do
      it "passes system to with_instructions and user to ask" do
        chain.invoke({system: "You are helpful.", user: "Hello"})
        expect(fake_chat).to have_received(:with_instructions).with("You are helpful.")
        expect(fake_chat).to have_received(:ask).with("Hello")
      end
    end

    context "with Hash input (message key)" do
      it "passes the message key to ask" do
        chain.invoke({message: "Alternative key"})
        expect(fake_chat).to have_received(:ask).with("Alternative key")
      end
    end

    context "with model option" do
      it "passes model to RubyLLM.chat when specified" do
        chain = described_class.new(model: "gpt-4o")
        chain.invoke("hello")
        expect(RubyLLM).to have_received(:chat).with(hash_including(model: "gpt-4o"))
      end

      it "calls chat with no args when model is not specified" do
        chain = described_class.new
        chain.invoke("hello")
        expect(RubyLLM).to have_received(:chat).with(no_args)
      end
    end

    context "with temperature option" do
      it "passes temperature to RubyLLM.chat when specified" do
        chain = described_class.new(temperature: 0.7)
        chain.invoke("hello")
        expect(RubyLLM).to have_received(:chat).with(hash_including(temperature: 0.7))
      end
    end

    context "with model from config" do
      it "uses config[:model]" do
        chain = described_class.new
        chain.invoke("hello", config: {model: "claude-3-5-sonnet"})
        expect(RubyLLM).to have_received(:chat).with(hash_including(model: "claude-3-5-sonnet"))
      end

      it "instance model takes precedence over config[:model]" do
        chain = described_class.new(model: "gpt-4o")
        chain.invoke("hello", config: {model: "claude-3-5-sonnet"})
        expect(RubyLLM).to have_received(:chat).with(hash_including(model: "gpt-4o"))
      end
    end

    context "with tools option" do
      it "registers each tool with with_tool" do
        tool_a = double("ToolA")
        tool_b = double("ToolB")
        chain = described_class.new(tools: [tool_a, tool_b])
        chain.invoke("hello")
        expect(fake_chat).to have_received(:with_tool).with(tool_a)
        expect(fake_chat).to have_received(:with_tool).with(tool_b)
      end
    end

    context "with provider option" do
      it "passes provider to RubyLLM.chat when specified" do
        chain = described_class.new(model: "openai/gpt-oss-20b", provider: :openai)
        chain.invoke("hello")
        expect(RubyLLM).to have_received(:chat).with(hash_including(provider: :openai))
      end

      it "auto-enables assume_model_exists when provider is given" do
        chain = described_class.new(model: "openai/gpt-oss-20b", provider: :openai)
        chain.invoke("hello")
        expect(RubyLLM).to have_received(:chat).with(hash_including(assume_model_exists: true))
      end

      it "does not set provider or assume_model_exists when provider is nil" do
        chain = described_class.new(model: "gpt-4o")
        chain.invoke("hello")
        expect(RubyLLM).to have_received(:chat) do |opts|
          expect(opts).not_to have_key(:provider)
          expect(opts).not_to have_key(:assume_model_exists)
        end
      end
    end
  end

  describe "#stream" do
    subject(:chain) { described_class.new }

    it "passes a block to ask" do
      received_block = nil
      allow(fake_chat).to receive(:ask) do |_msg, &blk|
        received_block = blk
        fake_message
      end

      chain.stream("hello") { |chunk| chunk }
      expect(received_block).not_to be_nil
    end

    it "returns the response text" do
      allow(fake_chat).to receive(:ask).and_yield("chunk").and_return(fake_message)
      result = chain.stream("hello") { |_c| }
      expect(result).to eq("Hello from LLM")
    end

    it "works with a system + user Hash" do
      chain.stream({system: "You are helpful.", user: "Hi"}) { |_c| }
      expect(fake_chat).to have_received(:with_instructions).with("You are helpful.")
    end
  end

  describe "as a Runnable" do
    subject(:chain) { described_class.new }

    it "batch processes multiple inputs" do
      results = chain.batch(["Q1", "Q2"])
      expect(results).to eq(["Hello from LLM", "Hello from LLM"])
      expect(RubyLLM).to have_received(:chat).twice
    end

    it "can be chained with >> into a Sequential" do
      other = described_class.new
      pipeline = chain >> other
      expect(pipeline).to be_a(Phronomy::Chain::Sequential)
    end
  end
end
