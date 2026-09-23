# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Workflow stream EventLoop integration" do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, default: 0
    end
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  it "observes stable states while using the same FSMSession path as invoke" do
    callback_threads = []
    states = []

    workflow = Phronomy::Workflow.define(context_class) do
      initial :first
      state :first, action: ->(context) {
        context.merge(value: 1)
      }
      state :second, action: ->(context) {
        context.merge(value: 2)
      }

      transition from: :first, to: :second
      transition from: :second, to: :__finish__
    end

    caller_thread = Thread.current
    event_loop = Phronomy::Runtime.instance.event_loop
    on_event_loop = []
    result = workflow.stream({}) do |event|
      callback_threads << Thread.current
      on_event_loop << event_loop.current?
      states << [event[:state], event[:context].value]
    end

    expect(states).to eq([[:first, 1], [:second, 2]])
    expect(callback_threads).to all(satisfy { |thread|
      thread != caller_thread
    })
    expect(on_event_loop).to all(be(true))
    expect(result.value).to eq(2)
  end

  it "loads and saves Persistence workflow_states like invoke and invoke_async" do
    persistence = Phronomy::Persistence.in_memory
    persistence.workflow_states.save(
      "stream-state",
      expected_revision: nil,
      snapshot: {
        fields: {value: 10},
        phase: "__end__"
      }
    )

    workflow = Phronomy::Workflow.define(
      context_class,
      persistence: persistence
    ) do
      initial :increment
      state :increment, action: ->(context) {
        context.merge(value: context.value + 1)
      }
      transition from: :increment, to: :__finish__
    end

    result = workflow.stream(
      {},
      config: {workflow_instance_id: "stream-state"}
    ) { |_event| }

    expect(result.value).to eq(11)
    record = persistence.workflow_states.load("stream-state")
    expect(record[:snapshot]["fields"]["value"]).to eq(11)
    expect(record[:revision]).to eq(2)
  end

  it "propagates observer exceptions to the synchronous caller" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :only
      state :only
      transition from: :only, to: :__finish__
    end

    expect {
      workflow.stream({}) { raise "observer failed" }
    }.to raise_error(RuntimeError, "observer failed")
  end

  [false, true].each do |durable|
    %i[wait leaf].each do |boundary|
      it "releases #{durable ? "durable" : "ephemeral"} #{boundary} completion when its observer raises" do
        persistence = durable ? Phronomy::Persistence.in_memory : nil
        workflow = Phronomy::Workflow.define(context_class, persistence: persistence) do
          initial :last
          if boundary == :wait
            wait_state :last
          else
            state :last
          end
        end
        id = "terminal-observer-#{durable}-#{boundary}"
        event_loop = Phronomy::Runtime.instance.event_loop
        registry = Phronomy::WorkflowExecutionRegistry.for(event_loop)
        original_error = RuntimeError.new("terminal observer failed")
        observed = Queue.new
        returned = Queue.new
        caller = Thread.new do
          value = workflow.stream({}, config: {workflow_instance_id: id}) do |event|
            observed << [event[:state], event_loop.current?, registry.workflow_admission_fsm_session_id(id)]
            raise original_error
          end
          returned << value
        rescue => error
          returned << error
        end

        expect(caller.join(2)).not_to be_nil, "terminal observer failure left stream waiting"
        expect(returned.pop).to equal(original_error)
        expect(observed.size).to eq(1)
        state, on_event_loop, fsm_id = observed.pop
        expect(state).to eq(:last)
        expect(on_event_loop).to be(true)
        expect(registry.workflow_admission_owner(id)).to be_nil
        expect(event_loop.admitted_fsm_session?(fsm_id)).to be(false)
        if durable
          record = persistence.workflow_states.load(id)
          expect(record[:revision]).to eq(1)
          expect(record[:snapshot]).to eq(
            "fields" => {"value" => 0},
            "phase" => (boundary == :wait) ? "last" : "__end__"
          )
        end
      ensure
        if caller&.alive?
          # Bounded cleanup also lets this regression run on an unfixed checkout.
          fsm_id = registry.workflow_admission_fsm_session_id(id)
          event_loop.post(Phronomy::Event.new(
            type: :error,
            target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {fsm_session_id: fsm_id, result: original_error}
          ))
          caller.join(2)
        end
      end
    end
  end
end
