# frozen_string_literal: true

require_relative "../common/configuration_error"

module Phronomy
  module Agent
    # Agent-owned option values and policy validation. Composition supplies
    # concrete components and default values; execution reads at existing sites.
    # @api private
    class Settings
      class << self
        # Bind at boot without reading settings or starting runtime resources.
        def install_provider(&provider)
          raise ArgumentError, "settings provider requires a block" unless provider
          @provider = provider
          nil
        end

        # Read only when requested; no cache or change notification is involved.
        def current
          @provider.call
        end
      end

      STREAM_CALLBACK_ERROR_POLICIES = %i[report fail_task].freeze
      private_constant :STREAM_CALLBACK_ERROR_POLICIES

      attr_accessor :default_model, :before_llm_input, :agent_store, :llm_adapter, :authorization_timeout
      attr_reader :stream_callback_error_policy

      def initialize(llm_adapter:, authorization_timeout:, stream_callback_error_policy:)
        @llm_adapter = llm_adapter
        @authorization_timeout = authorization_timeout
        self.stream_callback_error_policy = stream_callback_error_policy
      end

      def stream_callback_error_policy=(value)
        unless STREAM_CALLBACK_ERROR_POLICIES.include?(value)
          allowed = STREAM_CALLBACK_ERROR_POLICIES.map(&:inspect).join(", ")
          raise Phronomy::ConfigurationError,
            "stream_callback_error_policy must be one of: #{allowed}"
        end
        @stream_callback_error_policy = value
      end
    end
  end
end
