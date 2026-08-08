# frozen_string_literal: true

module Phronomy
  module Agent
    class ActivationRegistry
      def initialize
        @mutex = Mutex.new
        @records = {}
      end

      def register(activation)
        @mutex.synchronize do
          raise ArgumentError, "activation already registered: #{activation.execution_id}" if @records.key?(activation.execution_id)
          @records[activation.execution_id] = activation
        end
        activation
      end

      def fetch(execution_id)
        @mutex.synchronize { @records[execution_id.to_s] }
      end

      def delete(execution_id)
        @mutex.synchronize { @records.delete(execution_id.to_s) }
      end
    end
  end
end
