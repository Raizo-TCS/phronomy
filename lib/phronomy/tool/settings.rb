# frozen_string_literal: true

require_relative "../common/configuration_error"

module Phronomy
  module Tool
    # Tool-owned defaults. Composition supplies values; result processing reads
    # them at its existing boundary, after execution or asynchronous completion.
    # @api private
    class Settings
      def self.install_provider(&provider)
        raise ArgumentError, "Tool settings provider requires a block" unless provider

        @provider = provider
        nil
      end

      # Resolve the current value container without caching or notifications.
      def self.current
        settings = @provider&.call
        unless settings.is_a?(Settings)
          raise ConfigurationError, "Tool settings provider must return Tool::Settings"
        end

        settings
      end

      attr_accessor :max_result_size
    end
  end
end
