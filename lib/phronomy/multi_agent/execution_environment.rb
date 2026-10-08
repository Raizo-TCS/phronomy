# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Process-local connection selected by composition. MultiAgent owns the
    # admission and Team identity rules; the environment connects their
    # registries to shutdown and submits work to the originating executor.
    # Environments and registries are never durable execution authority.
    # @api private
    class ExecutionEnvironment
      class << self
        def install_provider(provider)
          raise ArgumentError, "MultiAgent execution provider must be callable" unless provider.respond_to?(:call)
          @provider = provider
        end

        def current
          @provider&.call || raise(Phronomy::ConfigurationError, "MultiAgent execution environment has not been configured")
        end
      end

      def admissions = raise(NotImplementedError)
      def ownership = raise(NotImplementedError)
      def existing_ownership = raise(NotImplementedError)
      def current? = raise(NotImplementedError)
      def submit(**options, &operation) = raise(NotImplementedError)
    end
  end
end
