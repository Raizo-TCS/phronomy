# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent owns this fresh-instance construction contract. Application
    # composition supplies the concrete default once during loading.
    # @api private
    module DefaultPersistence
      FACTORIES = {}
      private_constant :FACTORIES

      # A private boot binding, not an application extension registry.
      # @api private
      def self.install_factory(factory)
        raise ArgumentError, "factory must respond to call" unless factory.respond_to?(:call)

        FACTORIES.replace(persistence: factory).freeze
        nil
      end

      # Invoke only after explicit and configured instances have been excluded.
      # No instance is cached, shared, or installed in global configuration.
      # @api private
      def self.build
        FACTORIES.fetch(:persistence).call
      end
    end
  end
end
