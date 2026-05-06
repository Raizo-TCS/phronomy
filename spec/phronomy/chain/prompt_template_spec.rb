# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Phronomy::Chain::PromptTemplate do
  describe "#invoke" do
    context "with template only" do
      let(:pt) { described_class.new(template: "Hello, <%= name %>!") }

      it "renders the template and returns it under the :user key" do
        result = pt.invoke({name: "Ruby"})
        expect(result[:user]).to eq("Hello, Ruby!")
      end

      it "does not include the :system key" do
        result = pt.invoke({name: "Ruby"})
        expect(result).not_to have_key(:system)
      end
    end

    context "with system_template only" do
      let(:pt) { described_class.new(system_template: "You are <%= role %>.") }

      it "returns the rendered template under the :system key" do
        result = pt.invoke({role: "an assistant"})
        expect(result[:system]).to eq("You are an assistant.")
      end

      it "does not include the :user key" do
        result = pt.invoke({role: "an assistant"})
        expect(result).not_to have_key(:user)
      end
    end

    context "with both template and system_template" do
      let(:pt) do
        described_class.new(
          system_template: "You are <%= role %>.",
          template: "Answer: <%= question %>"
        )
      end

      it "returns both :system and :user keys" do
        result = pt.invoke({role: "a helpful assistant", question: "What is Ruby?"})
        expect(result[:system]).to eq("You are a helpful assistant.")
        expect(result[:user]).to eq("Answer: What is Ruby?")
      end
    end

    context "advanced ERB features" do
      it "supports conditionals" do
        pt = described_class.new(template: "<%= lang == 'ja' ? 'Konnichiwa' : 'Hello' %>")
        expect(pt.invoke({lang: "ja"})[:user]).to eq("Konnichiwa")
        expect(pt.invoke({lang: "en"})[:user]).to eq("Hello")
      end

      it "supports loops" do
        pt = described_class.new(template: "<% items.each do |i| %><%= i %><% end %>")
        result = pt.invoke({items: %w[a b c]})[:user]
        expect(result).to eq("abc")
      end
    end

    context "as a Runnable" do
      let(:pt) { described_class.new(template: "Hello, <%= name %>!") }

      it "stream yields to a block" do
        chunks = []
        pt.stream({name: "World"}) { |c| chunks << c }
        expect(chunks.first[:user]).to eq("Hello, World!")
      end

      it "batch processes multiple inputs" do
        results = pt.batch([{name: "Alice"}, {name: "Bob"}])
        expect(results.map { |r| r[:user] }).to eq(["Hello, Alice!", "Hello, Bob!"])
      end
    end
  end

  describe ".from_file" do
    it "loads the template from a file" do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/prompt.txt", "Hello, <%= name %>!")
        pt = described_class.from_file("#{dir}/prompt.txt")
        expect(pt.invoke({name: "File"})[:user]).to eq("Hello, File!")
      end
    end

    it "also loads the system prompt when system_path is specified" do
      Dir.mktmpdir do |dir|
        File.write("#{dir}/system.txt", "You are <%= role %>.")
        File.write("#{dir}/prompt.txt", "Question: <%= q %>")
        pt = described_class.from_file("#{dir}/prompt.txt", system_path: "#{dir}/system.txt")
        result = pt.invoke({role: "assistant", q: "test"})
        expect(result[:system]).to eq("You are assistant.")
        expect(result[:user]).to eq("Question: test")
      end
    end
  end

  describe ".with_sections" do
    it "combines sections into a system prompt" do
      pt = described_class.with_sections(
        role: "You are an assistant.",
        task: "Answer questions clearly."
      )
      result = pt.invoke({})[:system]
      expect(result).to include("# ROLE")
      expect(result).to include("You are an assistant.")
      expect(result).to include("# TASK")
      expect(result).to include("Answer questions clearly.")
    end
  end
end
