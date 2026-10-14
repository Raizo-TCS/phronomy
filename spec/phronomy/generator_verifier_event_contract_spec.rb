# frozen_string_literal: true

require "spec_helper"
require "timeout"

# Domain event interpretation is tested through the private Generation operation
# port. Public Agent/TaskResult binding is covered by agent_operation_spec and
# the real-Agent GeneratorVerifier integration suite.
RSpec.describe Phronomy::GeneratorVerifier do
  let(:draft_json) { '{"answer":"answer","confidence":0.9,"citations":[{"source":"ref"}]}' }
  let(:review_json) { '{"approved":true,"score":0.8,"feedback":"accepted"}' }
  let(:prompts) { [] }

  before do
    operation = described_class.const_get(:AgentOperation)
    allow(operation).to receive(:new) { |agent_class, **_options| agent_class.new }
  end

  def event(type, payload = {})
    if type == :done && payload[:output].is_a?(String)
      payload = payload.merge(output: JSON.parse(payload[:output]))
    end
    Phronomy::Agent::StreamEvent.new(type: type, payload: payload)
  end

  def scripted_agent(&script)
    Class.new do
      define_method(:start) do |input, listener:, **keywords|
        task = Phronomy::TaskResult.new(name: "generator-verifier-contract")
        script.call(input, ->(event) {
          value = listener.call(event)
          task.complete(nil) if %i[done error timeout cancelled].include?(event.type)
          value
        }, keywords)
        task
      end
    end
  end

  def emitting_agent(type, payload)
    scripted_agent { |_input, listener| listener.call(event(type, payload)) }
  end

  def pipeline(**options)
    described_class.new(
      draft_agent: emitting_agent(:done, {output: draft_json}),
      review_agent: emitting_agent(:done, {output: review_json}),
      draft_prompt_builder: ->(input, feedback) {
        prompts << [:draft, input, feedback]
        "draft prompt"
      },
      review_prompt_builder: ->(input, draft, citations) {
        prompts << [:review, input, draft, citations]
        "review prompt"
      },
      **options
    )
  end

  def invoke_bounded(subject, input = "request", config: {})
    Timeout.timeout(3) { subject.invoke(input, config: config) }
  end

  it "accepts inline completion before entry returns and ignores nonterminal events and pending Tasks" do
    draft = scripted_agent do |_input, listener|
      listener.call(event(:delta, {content: "ignored"}))
      listener.call(event(:done, {output: draft_json}))
    end
    result = invoke_bounded(pipeline(draft_agent: draft))

    expect(result.to_h).to eq(
      output: "answer", confidence: 0.8, citations: [{"source" => "ref"}],
      iterations: 1, review_notes: ["accepted"], confidence_threshold: 0.7,
      review_approved: true, termination_reason: "accepted", interrupted_phase: nil, failure: nil
    )
    expect(prompts).to eq([
      [:draft, "request", nil], [:review, "request", "answer", [{"source" => "ref"}]]
    ])
  end

  %i[draft review].each do |phase|
    %i[error timeout cancelled].each do |type|
      it "retains the original #{phase} #{type} exception" do
        error = RuntimeError.new("#{phase} #{type}")
        subject = pipeline("#{phase}_agent": emitting_agent(type, {error: error}))
        expect { invoke_bounded(subject) }.to raise_error { |raised| expect(raised).to equal(error) }
      end

      it "supplies the existing fallback for a #{phase} #{type} without an error" do
        subject = pipeline("#{phase}_agent": emitting_agent(type, {}))
        expect { invoke_bounded(subject) }
          .to raise_error(Phronomy::Error, "#{phase.to_s.capitalize} Agent ended with #{type}")
      end
    end

    it "maps an exception from #{phase} completion notification to the corresponding failure" do
      error = RuntimeError.new("completion notification failed")
      subject = pipeline
      workflow = subject.send(:compiled_workflow)
      notifications = []
      allow(workflow).to receive(:signal).and_wrap_original do |original, **values|
        notifications << values
        raise error if values[:event] == :"#{phase}_completed"
        original.call(**values)
      end
      expect { invoke_bounded(subject) }.to raise_error { |raised| expect(raised).to equal(error) }
      completion, failure = notifications.last(2)
      expect(failure[:event]).to eq(:"#{phase}_failed")
      expect(failure[:workflow_instance_id]).to eq(completion[:workflow_instance_id])
      expect(failure[:payload]).to eq(request_id: completion[:payload][:request_id], error: error)
    end

    it "does not wrap or retry a #{phase} failure notification exception" do
      listeners = []
      output = (phase == :draft) ? draft_json : review_json
      agent = scripted_agent do |_input, listener|
        listeners << listener
        listener.call(event(:done, {output: output}))
      end
      subject = pipeline("#{phase}_agent": agent)
      invoke_bounded(subject)
      workflow = subject.send(:compiled_workflow)
      error = RuntimeError.new("failure notification failed")
      expect(workflow).to receive(:signal).once.with(
        hash_including(event: :"#{phase}_failed")
      ).and_raise(error)
      expect { listeners.first.call(event(:error, {error: RuntimeError.new("agent failed")})) }
        .to raise_error { |raised| expect(raised).to equal(error) }
    end

    it "returns false without retry when a late #{phase} completion is not admitted" do
      listeners = []
      output = (phase == :draft) ? draft_json : review_json
      agent = scripted_agent do |_input, listener|
        listeners << listener
        listener.call(event(:done, {output: output}))
      end
      subject = pipeline("#{phase}_agent": agent)
      invoke_bounded(subject)
      workflow = subject.send(:compiled_workflow)
      expect(workflow).to receive(:signal).once.with(
        hash_including(event: :"#{phase}_completed")
      ).and_return(false)
      expect(listeners.first.call(event(:done, {output: output}))).to be(false)
    end
  end

  it "rejects duplicate and old request completions/failures across retries" do
    draft_listeners = []
    review_listeners = []
    draft = scripted_agent do |_input, listener|
      if draft_listeners.any?
        draft_listeners.first.call(event(:error, {error: RuntimeError.new("stale draft")}))
        draft_listeners.first.call(event(:done, {output: draft_json}))
      end
      draft_listeners << listener
      2.times { listener.call(event(:done, {output: draft_json})) }
    end
    review = scripted_agent do |_input, listener|
      if review_listeners.any?
        review_listeners.first.call(event(:error, {error: RuntimeError.new("stale review")}))
        review_listeners.first.call(event(:done, {output: review_json}))
      end
      review_listeners << listener
      output = (review_listeners.length == 1) ?
        '{"approved":false,"score":0.2,"feedback":"revise"}' : review_json
      2.times { listener.call(event(:done, {output: output})) }
    end
    subject = pipeline(draft_agent: draft, review_agent: review, max_iterations: 3)
    result = invoke_bounded(subject)

    expect(result.iterations).to eq(2)
    expect(result.review_notes).to eq(["revise", "accepted"])
    expect(result).to be_accepted
    expect(prompts.select { |entry| entry.first == :draft }.map(&:last)).to eq([nil, "revise"])
    expect([draft_listeners.length, review_listeners.length]).to eq([2, 2])
  end

  [[0.2, 0.8, 0.2], [0.9, 0.8, 0.8], [0, 1, 0]].each do |self_score, review_score, expected|
    it "uses the lower validated score #{self_score}/#{review_score}" do
      subject = pipeline(max_iterations: 1,
        draft_agent: emitting_agent(:done, {output: {"answer" => "answer", "confidence" => self_score, "citations" => []}}),
        review_agent: emitting_agent(:done, {output: {"approved" => true, "score" => review_score, "feedback" => ""}}))
      expect(invoke_bounded(subject).confidence).to eq(expected)
    end
  end

  it "rejects high-score reviewer denial under the requested raise policy" do
    subject = pipeline(max_iterations: 1, raise_if_unaccepted: true,
      review_agent: emitting_agent(:done, {output: {"approved" => false, "score" => 0.9, "feedback" => "rejected"}}))
    expect { invoke_bounded(subject) }.to raise_error(described_class::UnacceptedResultError)
  end

  it "rejects a nonpositive iteration limit before acquiring Agents" do
    expect { pipeline(max_iterations: 0) }.to raise_error(ArgumentError)
  end

  it "reuses owned Agents and starts each invoke with fresh state" do
    subject = pipeline
    operation = described_class.const_get(:AgentOperation)
    expect(operation).not_to receive(:new)
    first = invoke_bounded(subject, "first")
    second = invoke_bounded(subject, "second")
    expect([first.iterations, second.iterations]).to eq([1, 1])
    expect(second.review_notes).to eq(["accepted"])
    expect(prompts.select { |entry| entry.first == :draft }).to eq([
      [:draft, "first", nil], [:draft, "second", nil]
    ])
  end

  it "passes application config and a private cancellation token to Workflow" do
    subject = pipeline
    workflow = subject.send(:compiled_workflow)
    config = {user_id: "user", custom: "value"}
    expect(workflow).to receive(:invoke_async).with({input: "request"},
      config: hash_including(config.merge(cancellation_token: kind_of(Phronomy::Concurrency::CancellationToken)))).and_call_original
    expect(invoke_bounded(subject, config: config)).to be_accepted
  end

  %i[draft review].each do |phase|
    it "preserves an exception raised while starting #{phase}" do
      error = RuntimeError.new("start failed")
      agent = scripted_agent { raise error }
      subject = pipeline("#{phase}_agent": agent)
      expect { invoke_bounded(subject) }.to raise_error { |raised| expect(raised).to equal(error) }
    end
  end
end
