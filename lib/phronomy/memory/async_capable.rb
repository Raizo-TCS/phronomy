# frozen_string_literal: true

module Phronomy
  module Memory
    # When prepended onto a Memory::Base subclass, intercepts +save_messages+
    # and optionally defers the write to a background job via ActiveJob.
    #
    # Behaviour:
    # - async: false (default) — +save_messages+ runs synchronously as before.
    # - async: true           — +save_messages+ enqueues
    #                           +Phronomy::Memory::AsyncSaveJob+ and returns
    #                           immediately. The job performs the actual write.
    #
    # If +async: true+ is requested but ActiveJob is not available,
    # +Phronomy::ConfigurationError+ is raised immediately.
    module AsyncCapable
      # Intercepts save_messages to enqueue an AsyncSaveJob when async mode is on.
      def save_messages(thread_id:, messages:, **opts)
        if @_async
          unless defined?(::ActiveJob)
            raise Phronomy::ConfigurationError,
              "async: true requires ActiveJob to be available. " \
              "Add 'activejob' (or 'rails') to your Gemfile."
          end

          Phronomy::Memory::AsyncSaveJob
            .set(queue: @_async_queue)
            .perform_later(memory: self, thread_id: thread_id, messages: messages)
        else
          super
        end
      end
    end
  end
end
