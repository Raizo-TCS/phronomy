# frozen_string_literal: true

# Contract tests for Phronomy::OutputParser::Base implementations (Issue #231).
#
# Usage:
#   it_behaves_like "an output parser" do
#     let(:parser)       { described_class.new }
#     let(:valid_input)  { "..." }   # a string the parser can parse successfully
#     let(:invalid_input){ "???"  }  # a string that triggers ParseError
#   end
#
# Callers must provide:
#   - `parser`        — a fresh output parser instance
#   - `valid_input`   — a String the parser can parse without error
#   - `invalid_input` — a String that causes parse to raise Phronomy::ParseError
RSpec.shared_examples "an output parser" do
  describe "inheritance" do
    it "is a subclass of Phronomy::OutputParser::Base" do
      expect(parser).to be_a(Phronomy::OutputParser::Base)
    end

    it "includes Phronomy::Runnable" do
      expect(parser).to be_a(Phronomy::Runnable)
    end
  end

  describe "interface" do
    it "responds to #parse" do
      expect(parser).to respond_to(:parse)
    end

    it "responds to #invoke" do
      expect(parser).to respond_to(:invoke)
    end
  end

  describe "#parse" do
    it "returns a non-nil value for valid input" do
      expect(parser.parse(valid_input)).not_to be_nil
    end

    it "raises Phronomy::ParseError for invalid input" do
      expect { parser.parse(invalid_input) }.to raise_error(Phronomy::ParseError)
    end

    it "accepts a String argument" do
      expect { parser.parse(valid_input) }.not_to raise_error
    end

    it "is idempotent — parsing the same input twice returns equal results" do
      r1 = parser.parse(valid_input)
      r2 = parser.parse(valid_input)
      expect(r1).to eq(r2)
    end
  end

  describe "#invoke" do
    it "returns a non-nil value for valid input" do
      expect(parser.invoke(valid_input)).not_to be_nil
    end

    it "accepts an object that responds to #to_s as input" do
      input_obj = double("input", to_s: valid_input)
      expect { parser.invoke(input_obj) }.not_to raise_error
    end

    it "delegates to #parse internally (raises ParseError on invalid input)" do
      expect { parser.invoke(invalid_input) }.to raise_error(Phronomy::ParseError)
    end
  end
end
