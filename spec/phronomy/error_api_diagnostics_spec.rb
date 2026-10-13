# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Error API diagnostics" do
  def with_cause(error, cause)
    raise error, cause: cause
  rescue => caught
    caught
  end

  it "keeps a storage reason in the cause without making it a persistence reason" do
    source = Phronomy::Storage::NotFoundError.new("missing", code: "storage.future_reason")
    translated = begin
      Phronomy::Persistence::StorageBoundary.call { raise source }
    rescue Phronomy::Persistence::NotFoundError => error
      error
    end
    expect(translated.code).to be_nil
    expect(translated.cause).to equal(source)
    saved = JSON.parse(JSON.generate(Phronomy::Error.diagnostic(translated)))
    restored = Phronomy::Agent::RecoverySupport.error_from_failure(saved)
    expect(restored).to be_instance_of(Phronomy::Error)
    expect(restored.code).to be_nil
    expect(restored.cause).to be_instance_of(Phronomy::Error)
    expect(restored.cause.code).to eq("storage.future_reason")
    expect(restored.cause.message).to include("Phronomy::Storage::NotFoundError: missing")
  end

  it "does not resolve saved class names and accepts old diagnostics" do
    expect(Object).not_to receive(:const_get)
    error = Phronomy::Error.from_diagnostic({"class" => "Unknown::FutureError", "message" => "failed", "code" => "future.reason"})
    expect(error).to be_instance_of(Phronomy::Error)
    expect(error.cause).to be_nil
    expect(error.code).to eq("future.reason")
    expect(Phronomy::Error.from_diagnostic({"message" => "old"}).message).to eq("Error: old")
  end

  it "bounds new cause data and never invents a code by truncating it" do
    error = Phronomy::Error.new("deep", code: "x" * 3000)
    5.times { error = with_cause(Phronomy::Error.new("m" * 3000), error) }
    diagnostic = Phronomy::Error.diagnostic(error)
    expect(diagnostic["message"].length).to eq(3000)
    expect(diagnostic.dig("cause", "message").length).to eq(2048)
    expect(diagnostic.dig("cause", "cause", "cause", "cause")).to eq("truncated" => true)
    long_code = Phronomy::Error.diagnostic(with_cause(Phronomy::Error.new, Phronomy::Error.new(code: "x" * 3000)))
    expect(long_code["cause"]).not_to have_key("code")
    expect(long_code.dig("cause", "truncated")).to be(true)
  end

  it "accepts codes without losing specialized attributes or existing constructors" do
    result = Struct.new(:confidence, :termination_reason).new(0.1, "iteration_limit")
    condition = Object.new
    resource = Struct.new(:id).new(:items)
    constructors = [
      ->(**kw) { Phronomy::StreamCallbackError.new(event_type: :token, original_error: IOError.new, result: result, **kw) },
      ->(**kw) { Phronomy::GeneratorVerifier::UnacceptedResultError.new(result, code: nil, **kw) },
      ->(**kw) { Phronomy::FilterBlockError.new("blocked", filter: :policy, **kw) },
      ->(**kw) { Phronomy::Storage::ConditionFailedError.new(condition, **kw) },
      ->(**kw) { Phronomy::Storage::UniqueConstraintError.new(resource: resource, constraint: :id, **kw) },
      ->(**kw) { Phronomy::ExecutionTimeoutError.new(outcomes: [], **kw) },
      ->(**kw) { Phronomy::ExecutionCancellationError.new(outcomes: [], **kw) }
    ]
    constructors.each do |build|
      expect(build.call.code).to be_nil
      coded = build.call(code: "app.reason")
      expect(coded.code).to eq("app.reason")
      expect(coded.message).to eq(build.call.message)
      expect { build.call(code: :invalid) }.to raise_error(ArgumentError)
    end
    expect(constructors[0].call.result).to equal(result)
    expect(constructors[1].call.result).to equal(result)
    expect(constructors[2].call.filter).to eq(:policy)
    expect(constructors[3].call.condition).to equal(condition)
    expect(constructors[4].call.resource).to eq(:items)
    expect(constructors[5].call.outcomes).to eq([])
  end
end
