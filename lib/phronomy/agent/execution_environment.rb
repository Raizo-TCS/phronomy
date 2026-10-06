# frozen_string_literal: true

module Phronomy
  module Agent
    # Process-local execution connection selected by composition. Agent owns
    # admission, progress, approval, durable outcome and recovery decisions;
    # this extension supplies serial delivery, session routing and resources.
    # Environments and session handles are never persistence authority.
    # @api private
    class ExecutionEnvironment
      class << self
        def install_provider(provider)
          raise ArgumentError, "Agent execution provider must be callable" unless provider.respond_to?(:call)
          @provider = provider
        end

        def current
          @provider&.call || raise(Phronomy::ConfigurationError, "Agent execution environment has not been configured")
        end
      end

      def registry = raise(NotImplementedError)
      def existing_registry = raise(NotImplementedError)
      def ownership = raise(NotImplementedError)
      def existing_ownership = raise(NotImplementedError)
      def executing? = raise(NotImplementedError)
      def session_phase(id) = raise(NotImplementedError)
      def submit(**options, &operation) = raise(NotImplementedError)
      def build_llm_client(adapter:) = raise(NotImplementedError)
      def build_agent_session(invocation:, resume_event: nil, resume_phase: nil) = raise(NotImplementedError)
      def build_tool_session(invocation:, parent_sink:, resume_event: nil, resume_phase: nil) = raise(NotImplementedError)
      def register_session(session, completion:) = raise(NotImplementedError)
    end
  end
end
