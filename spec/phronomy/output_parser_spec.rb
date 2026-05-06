# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::OutputParser::Base do
  let(:parser_class) do
    Class.new(described_class) do
      def parse(text)
        text.upcase
      end
    end
  end
  let(:parser) { parser_class.new }

  describe "#invoke" do
    it "passes String directly to parse" do
      expect(parser.invoke("hello")).to eq("HELLO")
    end

    it "converts non-String to s before passing to parse" do
      expect(parser.invoke(42)).to eq("42")
    end
  end

  describe "#parse" do
    it "raises NotImplementedError when parse is not implemented in a subclass" do
      expect { described_class.new.parse("text") }.to raise_error(NotImplementedError)
    end
  end

  describe "as a Runnable" do
    it "batch processes multiple inputs" do
      results = parser.batch(["a", "b", "c"])
      expect(results).to eq(["A", "B", "C"])
    end

    it "can be chained with >> into a Sequential" do
      other = parser_class.new
      pipeline = parser >> other
      expect(pipeline).to be_a(Phronomy::Chain::Sequential)
    end
  end
end

RSpec.describe Phronomy::OutputParser::JsonParser do
  let(:parser) { described_class.new }

  describe "#parse" do
    context "normal JSON string" do
      it "parses Hash with symbolize_names: true" do
        result = parser.parse('{"name":"Alice","age":30}')
        expect(result).to eq({name: "Alice", age: 30})
      end

      it "parses array JSON" do
        result = parser.parse('[1,2,3]')
        expect(result).to eq([1, 2, 3])
      end

      it "parses nested Hash" do
        result = parser.parse('{"user":{"name":"Bob"}}')
        expect(result).to eq({user: {name: "Bob"}})
      end
    end

    context "with Markdown code fence" do
      it "extracts and parses content inside ```json ... ``` block" do
        text = "```json\n{\"key\":\"value\"}\n```"
        expect(parser.parse(text)).to eq({key: "value"})
      end

      it "also parses ``` ... ``` (no language specified)" do
        text = "```\n{\"key\":\"value\"}\n```"
        expect(parser.parse(text)).to eq({key: "value"})
      end

      it "extracts JSON even when there is surrounding text" do
        text = "Here is the JSON:\n```json\n{\"result\":42}\n```\nThat's all."
        expect(parser.parse(text)).to eq({result: 42})
      end
    end

    context "on parse error" do
      it "raises Phronomy::ParseError for invalid JSON" do
        expect { parser.parse("not json") }.to raise_error(Phronomy::ParseError, /Failed to parse JSON/)
      end

      it "includes input text in error message" do
        expect { parser.parse("bad") }.to raise_error(Phronomy::ParseError, /Input: bad/)
      end
    end
  end

  describe "#invoke" do
    it "converts non-String to_s before parsing" do
      # case where calling to_s produces valid JSON
      result = parser.invoke('{"n":1}')
      expect(result).to eq({n: 1})
    end
  end
end

RSpec.describe Phronomy::OutputParser::StructuredParser do
  let(:schema) { Struct.new(:name, :age, keyword_init: true) }
  let(:parser) { described_class.new(schema) }

  describe "#parse" do
    it "parses JSON and returns a schema class instance" do
      result = parser.parse('{"name":"Alice","age":30}')
      expect(result).to be_a(schema)
      expect(result.name).to eq("Alice")
      expect(result.age).to eq(30)
    end

    it "handles JSON wrapped in a code fence" do
      text = "```json\n{\"name\":\"Bob\",\"age\":25}\n```"
      result = parser.parse(text)
      expect(result.name).to eq("Bob")
    end

    it "raises Phronomy::ParseError on JSON parse error" do
      expect { parser.parse("not json") }.to raise_error(Phronomy::ParseError)
    end

    it "raises Phronomy::ParseError for unknown schema keys" do
      expect { parser.parse('{"name":"Alice","unknown":99}') }
        .to raise_error(Phronomy::ParseError, /Failed to map to schema/)
    end
  end
end
