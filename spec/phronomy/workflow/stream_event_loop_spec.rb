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
    result = workflow.stream({}) do |event|
      callback_threads << Thread.current
      states << [event[:state], event[:context].value]
    end

    expect(states).to eq([[:first, 1], [:second, 2]])
    expect(callback_threads).to all(satisfy { |thread|
      thread != caller_thread
    })
    expect(result.value).to eq(2)
  end

  it "loads and saves StateStore snapshots like invoke and invoke_async" do
    store = Phronomy::StateStore::InMemory.new
    store.save(
      "stream-state",
      {
        fields: {value: 10},
        phase: "__end__"
      }
    )

    workflow = Phronomy::Workflow.define(
      context_class,
      state_store: store
    ) do
      initial :increment
      state :increment, action: ->(context) {
        context.merge(value: context.value + 1)
      }
      transition from: :increment, to: :__finish__
    end

    result = workflow.stream(
      {},
      config: {thread_id: "stream-state"}
    ) { |_event| }

    expect(result.value).to eq(11)
    expect(store.load("stream-state")[:fields][:value]).to eq(11)
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
end
