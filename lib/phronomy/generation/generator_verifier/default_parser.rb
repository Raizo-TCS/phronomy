# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    # Boot supplies the default concrete parser. The generation algorithm owns
    # its output interpretation and fallback, not the concrete parser selection.
    # @api private
    module DefaultParser
      FACTORIES = {}
      private_constant :FACTORIES

      # Private one-time composition binding; not an application registry.
      # @api private
      def self.install_factory(factory)
        raise ArgumentError, "factory must respond to call" unless factory.respond_to?(:call)

        FACTORIES.replace(parser: factory).freeze
        nil
      end

      # @api private
      def self.build
        FACTORIES.fetch(:parser).call
      end
    end
  end
end
