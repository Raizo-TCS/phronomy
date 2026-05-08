# frozen_string_literal: true

module Phronomy
  module Memory
    # Background job that performs a deferred memory write.
    #
    # Enqueued by AsyncCapable#save_messages when async mode is enabled on a
    # memory instance. Temporarily disables async mode on the memory object so
    # that save_messages runs synchronously inside the worker process, then
    # restores the original flag.
    #
    # @note In production, the memory object must be serializable by ActiveJob
    #   (e.g. respond to GlobalID or use a custom serializer). For in-process
    #   test suites using the +:test+ adapter, objects are passed by reference so
    #   no serialization is required in tests.
    class AsyncSaveJob < ::ActiveJob::Base
      # @param memory    [Phronomy::Memory::Base] the memory backend to write to
      # @param thread_id [String]                  conversation thread identifier
      # @param messages  [Array]                   messages to persist
      def perform(memory:, thread_id:, messages:)
        # Disable async flag so save_messages runs the real synchronous path.
        memory.instance_variable_set(:@_async, false)
        memory.save_messages(thread_id: thread_id, messages: messages)
      ensure
        memory.instance_variable_set(:@_async, true)
      end
    end
  end
end
