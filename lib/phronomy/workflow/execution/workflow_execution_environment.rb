# frozen_string_literal: true

module Phronomy
  # Workflow-owned connection requirements. Progress, admission and durable
  # outcome interpretation remain in Workflow; composition selects transport.
  # @api private
  class WorkflowExecutionEnvironment
    class << self
      def install_provider(provider)
        raise ArgumentError, "Workflow execution provider must be callable" unless provider.respond_to?(:call)
        @provider = provider
      end

      def current
        @provider&.call || raise(Phronomy::ConfigurationError, "Workflow execution environment has not been configured")
      end
    end

    def registry = raise(NotImplementedError)
    def existing_registry = raise(NotImplementedError)
    def executing? = raise(NotImplementedError)
    def submit(**options, &operation) = raise(NotImplementedError)
    def compile_transitions(**definition) = raise(NotImplementedError)
    def build_session(**options) = raise(NotImplementedError)
    def register_session(session, completion:) = raise(NotImplementedError)
  end
end
