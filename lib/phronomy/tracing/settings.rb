# frozen_string_literal: true

require_relative "../common/configuration_error"

module Phronomy
  module Tracing
    # Tracing owns recording options; application composition selects the tracer.
    # No concrete backend, execution resource or application facade belongs here.
    # @api private
    class Settings
      def self.install_provider(&provider)
        raise ArgumentError, "Tracing settings provider requires a block" unless provider

        @provider = provider
        nil
      end

      # Follow reset and scoped restoration only when a consumer already reads.
      def self.current
        settings = @provider&.call
        unless settings.is_a?(Settings)
          raise ConfigurationError, "Tracing settings provider must return Tracing::Settings"
        end

        settings
      end

      attr_accessor :tracer, :trace_pii

      def initialize(tracer:)
        @tracer = tracer
        @trace_pii = false
      end
    end
  end
end
