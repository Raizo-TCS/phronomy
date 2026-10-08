# frozen_string_literal: true

require_relative "../common/configuration_error"

module Phronomy
  # Neutral runtime values only. Application composition supplies the current
  # settings object; Tool and Tracing own their domain-specific settings.
  # @api private
  class RuntimeSettings
    # Bind the application's settings accessor without evaluating it at boot.
    # @api private
    def self.install_provider(&provider)
      raise ArgumentError, "RuntimeSettings provider requires a block" unless provider

      @provider = provider
      nil
    end

    # Resolve on every read so configuration reset/scoped restoration is visible.
    # @return [RuntimeSettings]
    # @api private
    def self.current
      settings = @provider&.call
      unless settings.is_a?(RuntimeSettings)
        raise ConfigurationError, "RuntimeSettings provider must return RuntimeSettings"
      end

      settings
    end

    attr_accessor :logger
    attr_accessor :event_loop_stop_grace_seconds
    attr_accessor :event_loop_starvation_threshold_seconds
    attr_accessor :event_loop_dispatch_threshold_seconds
    attr_accessor :offload_pool_size, :offload_queue_size
    attr_accessor :authorization_pool_size, :authorization_queue_size

    # @api private
    def initialize
      @event_loop_stop_grace_seconds = 5
      @event_loop_starvation_threshold_seconds = nil
      @event_loop_dispatch_threshold_seconds = nil
      @offload_pool_size = 10
      @offload_queue_size = 100
      @authorization_pool_size = 4
      @authorization_queue_size = 100
    end
  end
end
