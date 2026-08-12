# frozen_string_literal: true

module Phronomy
  # Holds global configuration for the entire framework.
  class Configuration
    STREAM_CALLBACK_ERROR_POLICIES = %i[report fail_task].freeze
    private_constant :STREAM_CALLBACK_ERROR_POLICIES

    attr_accessor :default_model
    attr_accessor :default_embedding_model
    attr_accessor :tracer
    attr_accessor :before_llm_input
    attr_accessor :default_output_reserve
    attr_accessor :recursion_limit
    attr_accessor :parallel_tool_execution
    attr_accessor :trace_pii
    attr_accessor :logger
    attr_accessor :event_loop_stop_grace_seconds
    attr_accessor :state_store
    attr_accessor :tool_result_max_size
    attr_accessor :llm_adapter
    attr_accessor :event_loop_starvation_threshold_seconds
    attr_accessor :event_loop_dispatch_threshold_seconds
    attr_reader :stream_callback_error_policy
    attr_accessor :blocking_io_pool_size
    attr_accessor :blocking_io_queue_size
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

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
      @trace_pii = false
      @parallel_tool_execution = false
      @event_loop_stop_grace_seconds = 5
      @llm_adapter = Phronomy::LLMAdapter::RubyLLM.new
      @event_loop_starvation_threshold_seconds = nil
      @event_loop_dispatch_threshold_seconds = nil
      @stream_callback_error_policy = :report
      @blocking_io_pool_size = 10
      @blocking_io_queue_size = 100
      @authorization_pool_size = 4
      @authorization_queue_size = 100
      @authorization_timeout = 5
    end
  end
end
