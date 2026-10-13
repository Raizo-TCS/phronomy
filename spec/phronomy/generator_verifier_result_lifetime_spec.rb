# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "GeneratorVerifier result and resource ownership" do
  let(:type) { Phronomy::GeneratorVerifier }
  let(:fields) do
    {output: +"answer", confidence: 0.9, citations: [{source: "reference", nested: [{page: 1}]}],
     iterations: 1, review_notes: ["review"], confidence_threshold: 0.7,
     review_approved: true, termination_reason: "accepted"}
  end

  it "round trips all semantic facts through hashes and JSON" do
    result = type::Result.new(**fields)
    [result.to_h, JSON.parse(JSON.generate(result.to_h))].each do |data|
      restored = type::Result.from_h(data)
      expect(restored).to eq(result)
      expect(restored.hash).to eq(result.hash)
      expect(restored).to be_accepted
    end
  end

  it "distinguishes review denial and threshold changes when comparing results" do
    accepted = type::Result.new(**fields)
    denied = type::Result.new(**fields.merge(review_approved: false, termination_reason: "iteration_limit"))
    higher_threshold = type::Result.new(**fields.merge(confidence_threshold: 0.95, termination_reason: "iteration_limit"))
    expect(accepted).not_to eq(denied)
    expect(accepted).not_to eq(higher_threshold)
    expect(denied).not_to be_accepted
    expect({accepted => :one, denied => :two}.length).to eq(2)
  end

  it "copies and freezes nested values without freezing the application's source" do
    input = fields
    result = type::Result.new(**input)
    input[:output].replace("changed")
    input[:citations][0][:nested][0][:page] = 7
    input[:review_notes] << "changed"
    expect(result.output).to eq("answer")
    expect(result.citations[0]["nested"][0]["page"]).to eq(1)
    expect(result.review_notes).to eq(["review"])
    expect { result.citations[0]["source"].replace("x") }.to raise_error(FrozenError)
    expect { result.review_notes << "x" }.to raise_error(FrozenError)
  end

  it "rejects a contradictory termination reason and incomplete normal results" do
    expect { type::Result.new(**fields.merge(review_approved: false)) }.to raise_error(ArgumentError)
    expect { type::Result.new(**fields.merge(confidence: nil)) }.to raise_error(ArgumentError)
    expect { type::Result.from_h(fields.merge(trusted: true)) }.to raise_error(ArgumentError)
    expect { type::Result.from_h(fields.merge("output" => "duplicate")) }.to raise_error(ArgumentError)
    expect { type::Result.new(**fields.merge(citations: [{:a => 1, "a" => 2}])) }.to raise_error(ArgumentError)
  end

  [Float::NAN, Float::INFINITY, -0.1, 1.1, "0.7"].each do |invalid|
    it "rejects invalid result threshold #{invalid.inspect}" do
      expect { type::Result.new(**fields.merge(confidence_threshold: invalid)) }.to raise_error(ArgumentError)
    end
  end

  it "keeps tool rejection as an unevaluated outcome through JSON" do
    result = type::Result.new(**fields.merge(output: nil, confidence: nil, review_approved: nil,
      iterations: 0, termination_reason: "tool_rejected", interrupted_phase: :draft))
    expect(type::Result.from_h(JSON.parse(JSON.generate(result.to_h)))).to eq(result)
    expect(result).not_to be_accepted
  end

  def agent_class(instances, role, failure: nil)
    Class.new do
      attr_accessor :unload_error
      attr_reader :unloads
      define_method(:initialize) do |on_event:|
        raise failure if failure
        @unloads = 0
        instances[role] = self
      end
      define_method(:unload!) do
        @unloads += 1
        raise @unload_error if @unload_error
        true
      end
    end
  end

  def options(instances, review_failure: nil)
    {draft_agent: agent_class(instances, :draft), review_agent: agent_class(instances, :review, failure: review_failure),
     draft_prompt_builder: ->(*) { "draft" }, review_prompt_builder: ->(*) { "review" }}
  end

  it "releases both owners and returns the block value" do
    agents = {}
    expect(type.open(**options(agents)) { :value }).to eq(:value)
    expect(agents.values.map(&:unloads)).to eq([1, 1])
  end

  it "requires a block before acquiring any Agent" do
    agents = {}
    expect { type.open(**options(agents)) }.to raise_error(ArgumentError)
    expect(agents).to be_empty
  end

  it "releases the draft Agent after partial construction and preserves the original exception" do
    agents = {}
    primary = IOError.new("review construction failed")
    expect { type.new(**options(agents, review_failure: primary)) }
      .to raise_error { |error| expect(error).to equal(primary) }
    expect(agents.fetch(:draft).unloads).to eq(1)
  end

  it "tries every owner, retains failures, and retries only failed releases" do
    agents = {}
    pipeline = type.new(**options(agents))
    failure = IOError.new("release failure")
    agents[:draft].unload_error = failure
    expect { pipeline.release! }.to raise_error(type::CleanupError) do |error|
      expect(error.pipeline).to equal(pipeline)
      expect(error.failures).to eq([{phase: :draft, error: failure}])
    end
    expect(agents.values.map(&:unloads)).to eq([1, 1])
    expect { pipeline.invoke("after partial release") }.to raise_error(Phronomy::Error)
    agents[:draft].unload_error = nil
    expect(pipeline.release!).to be true
    expect(agents.values.map(&:unloads)).to eq([2, 1])
    expect(pipeline.release!).to be false
  end

  it "preserves primary failure, cleanup failure and the recovery handle together" do
    agents = {}
    primary = IOError.new("business failure")
    cleanup = IOError.new("release failure")
    expect {
      type.open(**options(agents)) do
        agents[:draft].unload_error = cleanup
        raise primary
      end
    }.to raise_error(type::CleanupError) do |error|
      expect(error.primary_error).to equal(primary)
      expect(error.cause).to equal(primary)
      expect(error.failures.first[:error]).to equal(cleanup)
      agents[:draft].unload_error = nil
      expect(error.pipeline.release!).to be true
    end
  end

  it "keeps a successful block result when cleanup fails" do
    agents = {}
    value = Object.new
    expect {
      type.open(**options(agents)) do
        agents[:review].unload_error = IOError.new("release failed")
        value
      end
    }.to raise_error(type::CleanupError) do |error|
      expect(error.result).to equal(value)
      expect(error.primary_error).to be_nil
      agents[:review].unload_error = nil
      error.pipeline.release!
    end
  end
end
