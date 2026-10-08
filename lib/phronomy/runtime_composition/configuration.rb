# frozen_string_literal: true

require "forwardable"
require_relative "../configuration/runtime_settings"
require_relative "../agent/settings"
require_relative "../workflow/execution/workflow_settings"
require_relative "../tool/settings"
require_relative "../tracing/settings"

module Phronomy
  # Application-facing configuration composes domain options and neutral runtime
  # settings. Public accessors and constructor behavior stay unchanged.
  class Configuration
    extend Forwardable

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

    attr_accessor :default_embedding_model, :multi_agent_store

    # Preserve the public settings facade while each domain owns its values.
    def_delegators :@__agent_settings, :default_model, :default_model=
    def_delegators :@__agent_settings, :before_llm_input, :before_llm_input=
    def_delegators :@__agent_settings, :agent_store, :agent_store=
    def_delegators :@__agent_settings, :llm_adapter, :llm_adapter=
    def_delegators :@__agent_settings, :stream_callback_error_policy, :stream_callback_error_policy=
    def_delegators :@__agent_settings, :authorization_timeout, :authorization_timeout=
    def_delegators :@__workflow_settings, :recursion_limit, :recursion_limit=
    def_delegators :@__workflow_settings, :workflow_store, :workflow_store=
    def_delegators :@__runtime_settings, :authorization_pool_size, :authorization_pool_size=
    def_delegators :@__runtime_settings, :authorization_queue_size, :authorization_queue_size=

    # @api private
    attr_reader :__agent_settings, :__workflow_settings, :__tool_settings, :__tracing_settings

    # Engine access is bound by the composition root, not by Engine itself.
    # @api private
    attr_reader :__runtime_settings

    def tracer
      @__tracing_settings.tracer
    end

    def tracer=(value)
      @__tracing_settings.tracer = value
    end

    def trace_pii
      @__tracing_settings.trace_pii
    end

    def trace_pii=(value)
      @__tracing_settings.trace_pii = value
    end

    def logger
      @__runtime_settings.logger
    end

    def logger=(value)
      @__runtime_settings.logger = value
    end

    def tool_result_max_size
      @__tool_settings.max_result_size
    end

    def tool_result_max_size=(value)
      @__tool_settings.max_result_size = value
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
      @__workflow_settings = WorkflowSettings.new(recursion_limit: 25)
      @__runtime_settings = RuntimeSettings.new
      @__tool_settings = Tool::Settings.new
      @__tracing_settings = Tracing::Settings.new(tracer: DEFAULT_FACTORIES.fetch(:tracer).call)
      @__agent_settings = Agent::Settings.new(
        llm_adapter: DEFAULT_FACTORIES.fetch(:llm_adapter).call,
        stream_callback_error_policy: :report, authorization_timeout: 5
      )
      @multi_agent_store = nil
    end

    private

    # A scoped configuration copy owns its scalar settings while retaining the
    # same injected tracer/logger identities, just like the previous flat object.
    def initialize_copy(original)
      super
      @__runtime_settings = original.__runtime_settings.dup
      @__agent_settings = original.__agent_settings.dup
      @__workflow_settings = original.__workflow_settings.dup
      @__tool_settings = original.__tool_settings.dup
      @__tracing_settings = original.__tracing_settings.dup
    end
  end
end
