# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::CancellationToken, "callback lifecycle" do
  it "releases registered callbacks before delivering explicit cancellation" do
    token = described_class.new
    calls = []

    token.on_cancel { calls << :called }
    token.cancel!

    expect(calls).to eq([:called])
    expect(token.instance_variable_get(:@cancel_callbacks)).to be_empty
  end

  it "allows framework code to unregister a callback that is no longer needed" do
    token = described_class.new
    calls = []
    callback = -> { calls << :called }

    token.on_cancel(&callback)
    token.send(:unregister_cancel_callback, callback)
    token.cancel!

    expect(calls).to be_empty
  end
end
