# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Optional failure reason codes" do
  it "retains existing message-only exception semantics" do
    expect(Phronomy::Error.new.message).to eq("Phronomy::Error")
    error = Phronomy::ConfigurationError.new("existing message")
    expect(error.code).to be_nil
    expect(Phronomy::Error.diagnostic(error)).to eq(
      "class" => "Phronomy::ConfigurationError", "message" => "existing message"
    )
  end

  it "copies and freezes a supplied code without changing message or cause" do
    code = +"future.reason"
    cause = IOError.new("cause")
    caught = begin
      begin
        raise cause
      rescue IOError
        raise Phronomy::ConfigurationError.new("display text", code: code)
      end
    rescue Phronomy::ConfigurationError => error
      error
    end
    code.replace("changed")
    expect(caught.code).to eq("future.reason")
    expect(caught.code).to be_frozen
    expect(caught.cause).to equal(cause)
    expect(caught.backtrace.first).to include(__FILE__)
    expect(caught.exception("new message").code).to eq("future.reason")
  end

  it "rejects non-string reason codes" do
    expect { Phronomy::Error.new("message", code: 42) }.to raise_error(ArgumentError)
  end

  it "does not reinterpret foreign exception attributes" do
    foreign = Class.new(StandardError) { def code = 404 }.new("external")
    expect(Phronomy::Error.diagnostic(foreign)).not_to have_key("code")
  end

  it "preserves unknown codes through generic recovery diagnostics" do
    error = Phronomy::ConfigurationError.new("message", code: "future.unknown")
    saved = Phronomy::Agent::RecoverySupport.resolution_failure(error)
    expect(saved.fetch("code")).to eq("future.unknown")
    restored = Phronomy::Agent::RecoverySupport.error_from_failure(saved)
    expect(restored.code).to eq("future.unknown")
    expect(restored.message).to eq("Phronomy::ConfigurationError: message")
  end

  it "reads old diagnostics without guessing a code" do
    saved = {"class" => "Phronomy::ConfigurationError", "message" => "Cannot enqueue after finalize"}
    expect(Phronomy::Agent::RecoverySupport.error_from_failure(saved).code).to be_nil
  end
end
