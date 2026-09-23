# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Execution and recovery value conversion" do
  [
    [Phronomy::Agent::RuntimeRecordEncoder, :json_value, "unsupported canonical runtime value"],
    [Phronomy::Agent::RecoverySupport, :canonical_copy, "Recovery value is not canonically serializable"]
  ].each do |owner, method, diagnostic|
    describe "#{owner}.#{method}" do
      let(:convert) { ->(value) { owner.public_send(method, value) } }

      it "converts nested keys, symbols and to_h values without mutating the input" do
        record = Struct.new(:nested).new({1 => [:ready, true, false, nil, 3, 1.25]})
        input = {outer: [record]}
        expect(convert.call(input)).to eq("outer" => [{"nested" => {"1" => ["ready", true, false, nil, 3, 1.25]}}])
        expect(input.keys).to eq([:outer])
        expect(record.nested).to eq(1 => [:ready, true, false, nil, 3, 1.25])
      end

      it "rebuilds mutable containers but retains String values" do
        text = +"shared scalar"
        input = {"items" => [text].freeze}.freeze
        output = convert.call(input)
        expect(output).not_to equal(input)
        expect(output).not_to be_frozen
        expect(output.fetch("items")).not_to equal(input.fetch("items"))
        expect(output.fetch("items")).not_to be_frozen
        expect(output.fetch("items").first).to equal(text)
        expect(text).not_to be_frozen
      end

      it "keeps the last value after key stringification without sorting keys" do
        input = {:z => 1, "z" => 2, :a => 3}
        output = convert.call(input)
        expect(output).to eq("z" => 2, "a" => 3)
        expect(output.keys).to eq(%w[z a])
      end

      it "reports a nested unsupported value using the caller's exact diagnostic" do
        expect { convert.call({items: [Object.new]}) }
          .to raise_error(ArgumentError, "#{diagnostic}: Object")
      end

      it "preserves exceptions raised by an application's to_h" do
        error = ArgumentError.new("application conversion failed")
        object = Object.new
        object.define_singleton_method(:to_h) { raise error }
        expect { convert.call([object]) }.to raise_error { |caught| expect(caught).to equal(error) }
      end

      it "recursively handles the returned value of to_h without a new Hash restriction" do
        object = Object.new
        object.define_singleton_method(:to_h) { [:legacy, {state: :ready}] }
        expect(convert.call(object)).to eq(["legacy", {"state" => "ready"}])
      end

      it "leaves canonical number validation to the serialization boundary" do
        [Float::INFINITY, Float::NAN, -0.0, 9_007_199_254_740_992].each do |number|
          result = convert.call(number)
          expect(result).to equal(number)
          expect { Phronomy::CanonicalJSON.dump(result) }.to raise_error(ArgumentError)
        end
      end

      it "does not transcode or validate String encoding during tree conversion" do
        invalid = "\xff".b.force_encoding(Encoding::UTF_8)
        expect(convert.call(invalid)).to equal(invalid)
        expect { Phronomy::CanonicalJSON.dump(invalid) }.to raise_error(ArgumentError)
      end
    end
  end
end
