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

workflow = nil

workflow = Phronomy::Workflow.define(ImportContext) do
  initial :importing

  state :importing, action: ->(context) {
    task = Phronomy::Runtime.instance.spawn do
      # Replace with application-owned asynchronous work.
      100
    end

    task.on_complete do |record_count, error|
      workflow.signal(
        thread_id: context.thread_id,
        event: error ? :import_failed : :import_completed,
        payload: {
          record_count: record_count,
          error: error
        }
      )
    end

    # Do not return task. The state is active after this synchronous entry ends.
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
