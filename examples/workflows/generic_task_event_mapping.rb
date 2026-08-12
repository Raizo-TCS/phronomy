# frozen_string_literal: true

require "phronomy"

class ImportContext
  include Phronomy::WorkflowContext

  field :record_count, default: 0
  field :error_message

  def handle_fsm_event(event)
    case event.type
    when :import_completed
      self.record_count = event.payload[:record_count]
    when :import_failed
      self.error_message = event.payload[:error].message
    end
    false
  end
end

# Example application service for a genuinely blocking import operation.
# The worker Thread belongs to Phronomy's bounded BlockingAdapterPool; the
# Workflow itself never blocks EventLoop waiting for the operation.
def start_blocking_import_async
  Phronomy::Runtime.instance.blocking_io.submit do
    # Replace with blocking file/DB/network import work.
    100
  end
end

workflow = nil

workflow = Phronomy::Workflow.define(ImportContext) do
  initial :importing

  state :importing, action: ->(context) {
    operation = start_blocking_import_async

    operation.on_complete do |record_count, error|
      workflow.signal(
        thread_id: context.thread_id,
        event: error ? :import_failed : :import_completed,
        payload: {
          record_count: record_count,
          error: error
        }
      )
    end

    # Do not return the completion handle. The state remains active after this
    # synchronous action returns, and later completion arrives as an FSM event.
    context
  }

  state :completed
  state :failed

  transition from: :importing, on: :import_completed, to: :completed
  transition from: :importing, on: :import_failed, to: :failed
  transition from: :completed, to: :__finish__
  transition from: :failed, to: :__finish__
end

result = workflow.invoke({})
puts "Imported #{result.record_count} records"
