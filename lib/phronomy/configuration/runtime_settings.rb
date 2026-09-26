# frozen_string_literal: true

require_relative "../common/configuration_error"

module Phronomy
  # Engine-facing values only. Application composition supplies the current
  # settings object; this contract knows no Agent, adapter or tracer class.
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

    attr_accessor :tracer, :trace_pii, :logger
    attr_accessor :event_loop_stop_grace_seconds
    attr_accessor :event_loop_starvation_threshold_seconds
    attr_accessor :event_loop_dispatch_threshold_seconds
    attr_accessor :offload_pool_size, :offload_queue_size

    # The tracer is injected; selecting a concrete implementation belongs to
    # application composition. Explicit nil retains its existing meaning.
    # @api private
    def initialize(tracer:)
      @tracer = tracer
      @trace_pii = false
      @event_loop_stop_grace_seconds = 5
      @event_loop_starvation_threshold_seconds = nil
      @event_loop_dispatch_threshold_seconds = nil
      @offload_pool_size = 10
      @offload_queue_size = 100
    end
  end
end
