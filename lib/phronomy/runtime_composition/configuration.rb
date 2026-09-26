# frozen_string_literal: true

require_relative "../configuration/runtime_settings"

module Phronomy
  # Application-facing configuration composes domain options and neutral runtime
  # settings. Public accessors and constructor behavior stay unchanged.
  class Configuration
    STREAM_CALLBACK_ERROR_POLICIES = %i[report fail_task].freeze
    private_constant :STREAM_CALLBACK_ERROR_POLICIES

    DEFAULT_FACTORIES = {}
    private_constant :DEFAULT_FACTORIES

    # Bind fresh-instance factories once during application loading. Concrete
    # component selection belongs to runtime_composition, not configuration.
    # Applications replace instances through the existing configuration writers.
    # @api private
    def self.install_default_factories(tracer:, llm_adapter:)
      DEFAULT_FACTORIES.replace(tracer: tracer, llm_adapter: llm_adapter).freeze
      nil
    end

    attr_accessor :default_model
    attr_accessor :default_embedding_model
    attr_accessor :before_llm_input
    attr_accessor :recursion_limit
    attr_accessor :persistence
    attr_accessor :tool_result_max_size
    attr_accessor :llm_adapter
    attr_reader :stream_callback_error_policy
    attr_accessor :authorization_pool_size
    attr_accessor :authorization_queue_size
    attr_accessor :authorization_timeout

    def stream_callback_error_policy=(value)
      unless STREAM_CALLBACK_ERROR_POLICIES.include?(value)
        allowed = STREAM_CALLBACK_ERROR_POLICIES.map(&:inspect).join(", ")
        raise Phronomy::ConfigurationError,
          "stream_callback_error_policy must be one of: #{allowed}"
      end

      @stream_callback_error_policy = value
    end

    # Engine access is bound by the composition root, not by Engine itself.
    # @api private
    attr_reader :__runtime_settings

    def tracer
      @__runtime_settings.tracer
    end

    def tracer=(value)
      @__runtime_settings.tracer = value
    end

    def trace_pii
      @__runtime_settings.trace_pii
    end

    def trace_pii=(value)
      @__runtime_settings.trace_pii = value
    end

    def logger
      @__runtime_settings.logger
    end

    def logger=(value)
      @__runtime_settings.logger = value
    end

    def event_loop_stop_grace_seconds
      @__runtime_settings.event_loop_stop_grace_seconds
    end

    def event_loop_stop_grace_seconds=(value)
      @__runtime_settings.event_loop_stop_grace_seconds = value
    end

    def event_loop_starvation_threshold_seconds
      @__runtime_settings.event_loop_starvation_threshold_seconds
    end

    def event_loop_starvation_threshold_seconds=(value)
      @__runtime_settings.event_loop_starvation_threshold_seconds = value
    end

    def event_loop_dispatch_threshold_seconds
      @__runtime_settings.event_loop_dispatch_threshold_seconds
    end

    def event_loop_dispatch_threshold_seconds=(value)
      @__runtime_settings.event_loop_dispatch_threshold_seconds = value
    end

    def offload_pool_size
      @__runtime_settings.offload_pool_size
    end

    def offload_pool_size=(value)
      @__runtime_settings.offload_pool_size = value
    end

    def offload_queue_size
      @__runtime_settings.offload_queue_size
    end

    def offload_queue_size=(value)
      @__runtime_settings.offload_queue_size = value
    end

    def initialize
      @recursion_limit = 25
      @__runtime_settings = RuntimeSettings.new(tracer: DEFAULT_FACTORIES.fetch(:tracer).call)
      @llm_adapter = DEFAULT_FACTORIES.fetch(:llm_adapter).call
      @stream_callback_error_policy = :report
      @authorization_pool_size = 4
      @authorization_queue_size = 100
      @authorization_timeout = 5
      @persistence = nil
    end

    private

    # A scoped configuration copy owns its scalar settings while retaining the
    # same injected tracer/logger identities, just like the previous flat object.
    def initialize_copy(original)
      super
      @__runtime_settings = original.__runtime_settings.dup
    end
  end
end
