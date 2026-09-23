# frozen_string_literal: true

require "spec_helper"
require "timeout"

# These expectations run unchanged on the implementation before extraction.
RSpec.describe Phronomy::GeneratorVerifier do
  let(:draft_json) { '{"answer":"answer","confidence":0.9,"citations":[{"source":"ref"}]}' }
  let(:review_json) { '{"approved":true,"score":0.8,"feedback":"accepted"}' }
  let(:prompts) { [] }

  def event(type, payload = {})
    Phronomy::Agent::StreamEvent.new(type: type, payload: payload)
  end

  def scripted_agent(&script)
    Class.new do
      define_method(:__invoke_async_with_event_sink) do |input, on_event:, **keywords|
        script.call(input, on_event, keywords)
        # Completion is driven by the event, not by observing this pending Task.
        Phronomy::TaskResult.new(name: "generator-verifier-contract")
      end
      private :__invoke_async_with_event_sink
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
      output: "answer", confidence: 0.8, citations: [{source: "ref"}],
      iterations: 1, review_notes: ["accepted"], trusted: true
    )
    expect(prompts).to eq([
      [:draft, "request", nil], [:review, "request", "answer", [{source: "ref"}]]
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

    it "maps #{phase} approval suspension to the existing pipeline failure" do
      subject = pipeline("#{phase}_agent": emitting_agent(:approval_required, {}))
      expect { invoke_bounded(subject) }
        .to raise_error(Phronomy::Error, "GeneratorVerifier #{phase} Agent suspended for approval")
    end

    it "preserves the #{phase} parser's exception identity" do
      error = ArgumentError.new("parser failed")
      subject = pipeline("#{phase}_result_parser": ->(_output) { raise error })
      expect { invoke_bounded(subject) }.to raise_error { |raised| expect(raised).to equal(error) }
    end

    it "maps a malformed #{phase} parser result through the failure event" do
      subject = pipeline("#{phase}_result_parser": ->(_output) {})
      workflow = subject.send(:compiled_workflow)
      failures = []
      allow(workflow).to receive(:signal).and_wrap_original do |original, **values|
        failures << values if values[:event] == :"#{phase}_failed"
        original.call(**values)
      end
      expect { invoke_bounded(subject) }.to raise_error(NoMethodError) do |error|
        expect(failures.length).to eq(1)
        expect(failures.first[:payload][:error]).to equal(error)
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
    expect(result).to be_trusted
    expect(prompts.select { |entry| entry.first == :draft }.map(&:last)).to eq([nil, "revise"])
    expect([draft_listeners.length, review_listeners.length]).to eq([2, 2])
  end

  [[nil, "2", 0.0], ["1.2", "0.9", 0.9], ["-0.5", 0.8, 0.0]].each do |self_score, review_score, expected|
    it "normalizes #{self_score.inspect}/#{review_score.inspect} and uses the lower score" do
      subject = pipeline(
        max_iterations: 1,
        draft_result_parser: ->(_output) { {answer: 42, confidence: self_score, citations: [nil, "ignored", {"source" => "ref"}]} },
        review_result_parser: ->(_output) { {approved: true, score: review_score, feedback: nil} }
      )
      result = invoke_bounded(subject)
      expect(result.output).to eq("42")
      expect(result.confidence).to eq(expected)
      expect(result.citations).to eq([{source: "ref"}])
      expect(result.review_notes).to eq([""])
    end
  end

  [true, "true", 1].each do |approved|
    it "requires literal true for early approval: #{approved.inspect}" do
      subject = pipeline(
        max_iterations: 2,
        review_result_parser: ->(_output) { {approved: approved, score: 0.9, feedback: "review"} }
      )
      expect(invoke_bounded(subject).iterations).to eq((approved == true) ? 1 : 2)
    end
  end

  it "preserves confidence-based trust even when a high-score rejection reaches the limit" do
    subject = pipeline(
      max_iterations: 1, raise_if_untrusted: true,
      review_result_parser: ->(_output) { {approved: false, score: 0.9, feedback: "rejected"} }
    )
    expect(invoke_bounded(subject)).to be_trusted
  end

  it "retains the first draft/review cycle even with a nonpositive iteration limit" do
    expect(invoke_bounded(pipeline(max_iterations: 0)).iterations).to eq(1)
  end

  it "keeps bare citation hashes out of the normalized citation list" do
    subject = pipeline(draft_result_parser: ->(_output) { {answer: nil, confidence: 1, citations: {"source" => "ref"}} })
    result = invoke_bounded(subject)
    expect(result.output).to eq("")
    expect(result.citations).to eq([])
  end

  it "instantiates each Agent once lazily and starts each invoke with fresh state" do
    subject = pipeline
    draft = subject.instance_variable_get(:@draft_agent_class)
    review = subject.instance_variable_get(:@review_agent_class)
    expect(draft).to receive(:new).once.and_call_original
    expect(review).to receive(:new).once.and_call_original
    first = invoke_bounded(subject, "first")
    second = invoke_bounded(subject, "second")
    expect([first.iterations, second.iterations]).to eq([1, 1])
    expect(second.review_notes).to eq(["accepted"])
    expect(prompts.select { |entry| entry.first == :draft }).to eq([
      [:draft, "first", nil], [:draft, "second", nil]
    ])
  end

  it "passes config unchanged to the cached Workflow" do
    subject = pipeline
    workflow = subject.send(:compiled_workflow)
    config = {user_id: "user", custom: "value"}
    expect(workflow).to receive(:invoke).with({input: "request"}, config: config).and_call_original
    expect(invoke_bounded(subject, config: config)).to be_trusted
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
