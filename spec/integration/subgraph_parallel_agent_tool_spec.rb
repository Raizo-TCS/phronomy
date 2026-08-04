# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/llm_stub"
require "securerandom"

# Group 13: Subgraph nesting / Agent-as-Tool.
#
# Nested Workflow completion is integrated through the generic Task contract:
# the application registers Task#on_complete and maps it to a parent Workflow
# event. The parent entry action returns synchronously and is not implicitly
# awaited by Phronomy.
RSpec.describe "Group 13: Subgraph / Agent-as-Tool", :integration do
  class G13BaseState
    include Phronomy::WorkflowContext

    field :value, type: :replace
    field :step, type: :replace, default: 0
    field :log, type: :append, default: -> { [] }
    field :meta, type: :merge, default: -> { {} }
    field :subworkflow_request_id, type: :replace
    field :subworkflow_error, type: :replace

    def handle_fsm_event(event)
      case event.type
      when :subworkflow_completed
        return :consume unless
          event.payload[:request_id] == subworkflow_request_id

        self.value = event.payload[:value]
        self.step = event.payload[:step] if event.payload.key?(:step)
      when :subworkflow_failed
        return :consume unless
          event.payload[:request_id] == subworkflow_request_id

        self.subworkflow_error = event.payload[:error]
      end
      false
    end
  end

  class G13SubState
    include Phronomy::WorkflowContext

    field :value, type: :replace
    field :step, type: :replace, default: 0
  end

  def linear_subworkflow
    Phronomy::Workflow.define(G13SubState) do
      initial :s1
      state :s1
      state :s2

      entry :s1, ->(state) {
        state.value = "#{state.value}_s1"
        state.step += 1
      }
      entry :s2, ->(state) {
        state.value = "#{state.value}_s2"
        state.step += 1
      }

      transition from: :s1, to: :s2
      transition from: :s2, to: :__finish__
    end
  end

  def branching_subworkflow
    Phronomy::Workflow.define(G13SubState) do
      initial :router
      state :router
      state :high
      state :low

      entry :high, ->(state) {
        state.value = "high_#{state.value}"
        state.step += 1
      }
      entry :low, ->(state) {
        state.value = "low_#{state.value}"
        state.step += 1
      }

      transition from: :high, to: :__finish__
      transition from: :low, to: :__finish__
      transition(
        from: :router,
        guard: ->(state) {
          state.value.to_s.start_with?("h")
        },
        to: :high
      )
      transition from: :router, to: :low
    end
  end

  def signal_subworkflow_completion(
    parent_workflow:,
    parent_thread_id:,
    request_id:,
    task:
  )
    task.on_complete do |result, error|
      parent_workflow.signal(
        thread_id: parent_thread_id,
        event: error ? :subworkflow_failed : :subworkflow_completed,
        payload: {
          request_id: request_id,
          value: result&.value,
          step: result&.step,
          error: error
        }
      )
    end
  end

  it "TC-001: flat linear workflow executes all states in order" do
    app = Phronomy::Workflow.define(G13BaseState) do
      initial :a
      state :a
      state :b

      entry :a, ->(state) {
        state.value = "a"
        state.step += 1
      }
      entry :b, ->(state) {
        state.value = "#{state.value}_b"
        state.step += 1
      }

      transition from: :a, to: :b
      transition from: :b, to: :__finish__
    end

    final = app.invoke({})
    expect(final.value).to eq("a_b")
    expect(final.step).to eq(2)
  end

  it "TC-002: maps a linear sub-workflow Task into parent events" do
    subworkflow = linear_subworkflow
    completion_mapper = method(:signal_subworkflow_completion)
    parent_workflow = nil

    parent_workflow = Phronomy::Workflow.define(G13BaseState) do
      initial :before
      state :before
      state :nested
      state :after
      state :failed

      entry :before, ->(state) {
        state.merge(value: "init", step: 0)
      }

      entry :nested, ->(state) {
        request_id = SecureRandom.uuid
        next_state = state.merge(
          subworkflow_request_id: request_id,
          subworkflow_error: nil
        )
        task = subworkflow.invoke_async(
          {
            value: next_state.value,
            step: next_state.step
          }
        )

        completion_mapper.call(
          parent_workflow: parent_workflow,
          parent_thread_id: next_state.thread_id,
          request_id: request_id,
          task: task
        )

        next_state
      }

      entry :after, ->(state) {
        state.merge(value: "#{state.value}_after")
      }

      entry :failed, ->(state) {
        raise(
          state.subworkflow_error ||
          Phronomy::Error.new("Nested Workflow failed")
        )
      }

      transition(
        from: :nested,
        on: :subworkflow_completed,
        to: :after
      )
      transition(
        from: :nested,
        on: :subworkflow_failed,
        to: :failed
      )
      transition from: :before, to: :nested
      transition from: :after, to: :__finish__
    end

    final = parent_workflow.invoke({})
    expect(final.value).to eq("init_s1_s2_after")
    expect(final.step).to eq(2)
  end

  it "TC-003: maps a branching sub-workflow Task into parent events" do
    subworkflow = branching_subworkflow
    completion_mapper = method(:signal_subworkflow_completion)
    parent_workflow = nil

    parent_workflow = Phronomy::Workflow.define(G13BaseState) do
      initial :nested
      state :nested
      state :completed
      state :failed

      entry :nested, ->(state) {
        request_id = SecureRandom.uuid
        next_state = state.merge(
          subworkflow_request_id: request_id,
          subworkflow_error: nil
        )
        task = subworkflow.invoke_async(
          {value: "high_input", step: 0}
        )

        completion_mapper.call(
          parent_workflow: parent_workflow,
          parent_thread_id: next_state.thread_id,
          request_id: request_id,
          task: task
        )

        next_state
      }

      entry :failed, ->(state) {
        raise(
          state.subworkflow_error ||
          Phronomy::Error.new("Nested Workflow failed")
        )
      }

      transition(
        from: :nested,
        on: :subworkflow_completed,
        to: :completed
      )
      transition(
        from: :nested,
        on: :subworkflow_failed,
        to: :failed
      )
      transition from: :completed, to: :__finish__
    end

    final = parent_workflow.invoke({})
    expect(final.value).to start_with("high_")
    expect(final.step).to eq(1)
  end

  it "TC-008: AgentTool.from_agent generates the expected metadata" do
    stub_agent = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-14", version: 1
      def self.name
        "SummarizerAgent"
      end
    end

    tool_class = Phronomy::Tools::Agent.from_agent(
      stub_agent,
      description: "Summarizes long documents"
    )

    expect(tool_class.new.name).to eq("summarizer")
    expect(tool_class.description).to eq("Summarizes long documents")
    expect(tool_class.ancestors).to include(Phronomy::Tools::Agent)
  end

  it "TC-009: AgentTool respects an explicit tool_name" do
    stub_agent = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-15", version: 1
      def self.name
        "TranslatorAgent"
      end
    end

    tool_class = Phronomy::Tools::Agent.from_agent(
      stub_agent,
      tool_name: "my_translator",
      description: "Translates text"
    )

    expect(tool_class.new.name).to eq("my_translator")
  end

  it "TC-010: Base delegates to a wrapped sub-agent" do
    sub_agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-16", version: 1
      model LM_STUDIO_MODEL
      provider :openai
      instructions(
        "You are a math agent. Answer with only the numeric result."
      )
    end
    sub_agent_class.define_singleton_method(:name) { "MathAgent" }

    math_tool = Phronomy::Tools::Agent.from_agent(
      sub_agent_class,
      tool_name: "math_solver",
      description:
        "Solves arithmetic questions. Pass the full question as input."
    )

    parent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-17", version: 1
      model LM_STUDIO_MODEL
      provider :openai
      instructions(
        "Use the math_solver tool for math questions. " \
        "Do not answer directly."
      )
      tools math_tool
    end

    tool_response = LLMStub.tool_call_response(
      "math_solver",
      {
        input:
          "What is 12 multiplied by 9? Use the math_solver tool."
      }
    )
    LLMStub.activate(
      responses: [
        tool_response,
        "108",
        "The answer is 108."
      ]
    )

    result = parent_class.new.invoke(
      "What is 12 multiplied by 9? Use the math_solver tool."
    )

    expect(result[:output]).to be_a(String)
    expect(result[:output]).not_to be_empty
    expect(result[:output]).to include("108")
  ensure
    LLMStub.deactivate
  end
end
