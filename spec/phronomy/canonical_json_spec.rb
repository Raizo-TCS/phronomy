# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::CanonicalJSON do
  it "orders object keys and produces stable bytes" do
    expect(described_class.dump("b" => 2, "a" => 1)).to eq('{"a":1,"b":2}')
  end

  it "rejects Ruby-specific object keys" do
    expect { described_class.dump(a: 1) }
      .to raise_error(ArgumentError, /keys must be String/)
  end

  it "uses JCS-compatible decimal and exponent boundaries" do
    expect(described_class.dump(1.0)).to eq("1")
    expect(described_class.dump(1e20)).to eq("100000000000000000000")
    expect(described_class.dump(1e21)).to eq("1e+21")
    expect(described_class.dump(1e-6)).to eq("0.000001")
    expect(described_class.dump(1e-7)).to eq("1e-7")
  end

  it "rejects integers outside the interoperable safe range" do
    expect { described_class.dump(Phronomy::CanonicalJSON::MAX_SAFE_INTEGER + 1) }
      .to raise_error(ArgumentError, /safe range/)
  end

  it "rejects non-finite and negative-zero floats" do
    expect { described_class.dump("n" => Float::NAN) }
      .to raise_error(ArgumentError, /non-finite/)
    expect { described_class.dump("n" => -0.0) }
      .to raise_error(ArgumentError, /-0.0/)
  end
end
