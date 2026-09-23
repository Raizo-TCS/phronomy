# frozen_string_literal: true

require "spec_helper"

# Independent behavioral expectations: this spec also runs on the source before
# transition ownership was unified. Entry actions are isolated from providers.
RSpec.describe "Agent invocation transition contract" do
  let(:states) do
    %i[idle filtering_input building_context calling_llm starting_tools
      evaluating_tools waiting_for_tools dispatching_tools recording_tool_results
      suspended output_filtering handed_off completed blocked failed]
  end
  let(:tool_events) do
    %i[tool_authorized tool_approval_required tool_completed tool_failed tool_rejected tool_cancelled]
  end
  let(:guard_names) { %i[callback_failed? handoff_failed? handoff_requested? tool_call_pending?] }
  let(:tracker_class) { Phronomy::Agent::PhaseMachineBuilder.new.build }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "transition-contract-agent", version: 1
      model "test-model"
    end
  end
  let(:events) { [] }
  let(:event_loop) do
    double("event_loop").tap do |loop|
      allow(loop).to receive(:post) do |event|
        events << event
        true
      end
    end
  end
  let(:runtime) { double("runtime", event_loop: event_loop) }
  let(:session_builder) { Phronomy::Agent::AgentInvocationSessionBuilder }
  let(:session) do
    session_builder.build(
      agent: agent_class.new, input: "hello",
      config: {execution_id: "transition-contract"}, runtime: runtime
    )
  end

  before do
    allow(session_builder).to receive(:build_entry_actions).and_return({})
  end

  def handle(session, type)
    session.handle(Phronomy::Event.new(type: type, target_id: session.id, payload: nil))
  end

  def advance_automatic_events(session)
    while events.first&.type == :state_completed
      session.handle(events.shift)
    end
  end

  it "accepts exactly the declared source states for every external event" do
    expected = tool_events.to_h { |name| [name, {waiting_for_tools: :evaluating_tools}] }.merge(
      llm_completed: {calling_llm: :output_filtering},
      llm_failed: {calling_llm: :failed},
      llm_setup_failed: {calling_llm: :failed},
      tool_setup_failed: {dispatching_tools: :failed},
      tool_dispatch_prepared: {dispatching_tools: :evaluating_tools},
      resume: {suspended: :waiting_for_tools},
      application_callback_failed: %i[filtering_input building_context calling_llm
        starting_tools evaluating_tools waiting_for_tools dispatching_tools
        recording_tool_results output_filtering].to_h { |state| [state, :failed] }
    )
    metadata = session.instance_variable_get(:@external_events)
    expect(metadata.keys).to match_array(expected.keys)
    context = double("guards", **guard_names.to_h { |name| [name, false] })
    expected.each do |event_name, destinations|
      states.each do |source|
        tracker = tracker_class.new
        tracker.context = context
        tracker.phase = source.to_s
        target = destinations[source]
        expect(tracker.public_send(event_name)).to eq(!target.nil?), "#{source} / #{event_name}"
        expect(tracker.phase).to eq((target || source).to_s)
        declared = metadata.fetch(event_name).any? { |definition| definition[:from] == source }
        expect(declared).to eq(!target.nil?), "Session metadata: #{source} / #{event_name}"
      end
    end
  end

  16.times do |mask|
    it "preserves LLM guard priority and short circuiting for condition mask #{mask}" do
      calls = []
      context = Object.new
      flags = guard_names.each_with_index.map do |name, index|
        enabled = mask[index] == 1
        context.define_singleton_method(name) do
          calls << name
          enabled
        end
        enabled
      end
      tracker = tracker_class.new
      tracker.context = context
      tracker.phase = "calling_llm"
      expect(tracker.llm_completed).to be(true)
      first = flags.index(true)
      expect(tracker.phase).to eq(%w[failed failed handed_off starting_tools output_filtering][first || 4])
      expect(calls).to eq(guard_names.take((first || 3) + 1))
    end
  end

  it "uses the unconditional LLM fallback when the context is nil" do
    tracker = tracker_class.new
    tracker.phase = "calling_llm"
    expect(tracker.llm_completed).to be(true)
    expect(tracker.phase).to eq("output_filtering")
  end

  it "propagates the same guard exception without changing phase" do
    error = RuntimeError.new("guard failed")
    context = double("context")
    allow(context).to receive(:callback_failed?).and_raise(error)
    tracker = tracker_class.new
    tracker.context = context
    tracker.phase = "calling_llm"
    expect { tracker.llm_completed }.to raise_error { |raised| expect(raised).to be(error) }
    expect(tracker.phase).to eq("calling_llm")
  end

  it "keeps automatic, asynchronous, approval-wait and terminal boundaries distinct" do
    automatic = %i[idle filtering_input building_context starting_tools evaluating_tools recording_tool_results output_filtering]
    waiting = %i[calling_llm waiting_for_tools dispatching_tools]
    states.each do |state|
      current = session_builder.build(
        agent: agent_class.new, input: "hello",
        config: {execution_id: "boundary-#{state}"}, runtime: runtime
      )
      # Start at each boundary without running a provider or a Tool entry action.
      current.instance_variable_set(:@entry_point, state)
      events.clear
      current.start
      expected = if automatic.include?(state)
        [:state_completed]
      elsif waiting.include?(state)
        []
      elsif state == :suspended
        [:halted]
      else
        [:finished]
      end
      expect(events.map(&:type)).to eq(expected), "Session boundary: #{state}"
      expect(current.current_state).to eq(state)
    end
  end

  it "halts for approval and resumes through Tool evaluation and dispatch waiting" do
    invocation = session.context
    allow(invocation).to receive(:handle_fsm_event).and_return(false)
    invocation.pending_tool_calls = [double("tool_call")]
    allow(invocation).to receive(:approval_required?).and_return(true)
    session.start
    advance_automatic_events(session)
    expect(session.current_state).to eq(:calling_llm)
    handle(session, :llm_completed)
    advance_automatic_events(session)
    expect(session.current_state).to eq(:suspended)
    expect(events.map(&:type)).to eq([:halted])

    events.clear
    resumed = session_builder.build_for_resume(
      agent_invocation: invocation, resume_event: :resume,
      resume_phase: :suspended, runtime: runtime
    )
    expect(resumed.id).not_to eq(session.id)
    resumed.start
    expect(resumed.current_state).to eq(:waiting_for_tools)
    expect(events).to be_empty
    allow(invocation).to receive(:approval_required?).and_return(false)
    allow(invocation).to receive(:ready_to_dispatch?).and_return(true)
    handle(resumed, :tool_authorized)
    advance_automatic_events(resumed)
    expect(resumed.current_state).to eq(:dispatching_tools)
    expect(events).to be_empty
    allow(invocation).to receive(:ready_to_dispatch?).and_return(false)
    handle(resumed, :tool_dispatch_prepared)
    advance_automatic_events(resumed)
    expect(resumed.current_state).to eq(:waiting_for_tools)
    expect(events).to be_empty
  end

  it "applies the incoming context before choosing the LLM completion transition" do
    session.start
    advance_automatic_events(session)
    allow(session.context).to receive(:handle_fsm_event) do
      session.context.pending_tool_calls = [double("tool_call")]
      true
    end
    handle(session, :llm_completed)
    expect(session.current_state).to eq(:starting_tools)
    expect(events.map(&:type)).to eq([:state_completed])
  end

  it "reports a known event arriving at an undeclared source as an error" do
    session.start
    advance_automatic_events(session)
    allow(session.context).to receive(:handle_fsm_event).and_return(false)
    handle(session, :tool_completed)
    expect(events.map(&:type)).to eq([:error])
    expect(events.first.payload.fetch(:result)).to be_a(ArgumentError)
    expect(session.current_state).to eq(:calling_llm)
  end
end
