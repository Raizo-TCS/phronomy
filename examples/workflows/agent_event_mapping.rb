# frozen_string_literal: true

require "phronomy"
require "securerandom"

class GenerationContext
  include Phronomy::WorkflowContext

  field :prompt
  field :generation_request_id
  field :answer
  field :error_message

  # This is application logic. Phronomy transports the event and payload but
  # does not decide which Agent invocation is current or where the result lives.
  def handle_fsm_event(event)
    request_id = event.payload[:generation_request_id]
    return :consume unless request_id == generation_request_id

    case event.type
    when :generation_completed
      self.answer = event.payload[:agent_result][:output]
    when :generation_failed
      self.error_message = event.payload[:error].message
    end
    false
  end
end

class AnswerAgent < Phronomy::Agent::Base
  model "gpt-4o-mini"
  instructions "Answer clearly and briefly."
end

agent = AnswerAgent.new
workflow = nil

workflow = Phronomy::Workflow.define(GenerationContext) do
  initial :generating

  state :generating, action: ->(context) {
    request_id = context.generation_request_id

    # The Agent Task is intentionally not returned from the entry action.
    # The block is the application-level integration channel.
    agent.invoke_async(context.prompt) do |agent_event|
      workflow_event =
        case agent_event.type
        when :done
          :generation_completed
        when :error, :timeout, :cancelled, :approval_required
          :generation_failed
        end
      next unless workflow_event

      workflow.signal(
        thread_id: context.thread_id,
        event: workflow_event,
        payload: {
          generation_request_id: request_id,
          agent_result: (
            agent_event.payload if agent_event.type == :done
          ),
          error:
            agent_event.payload[:error] ||
            Phronomy::Error.new(
              "Agent requested Tool approval"
            )
        }
      )
    end

    context
  }

  state :succeeded
  state :failed

  transition(
    from: :generating,
    on: :generation_completed,
    to: :succeeded
  )
  transition(
    from: :generating,
    on: :generation_failed,
    to: :failed
  )
  transition from: :succeeded, to: :__finish__
  transition from: :failed, to: :__finish__
end

result = workflow.invoke(
  {
    prompt: "What is Run-to-Completion?",
    generation_request_id: SecureRandom.uuid
  },
  config: {thread_id: SecureRandom.uuid}
)

puts(result.answer || result.error_message)
