# frozen_string_literal: true

module Phronomy
  module Agent
    # Public Agent execution facade.
    #
    # CG-09 clean break:
    # - application event listeners are bound to the live Agent incarnation at
    #   new/create/load time;
    # - invoke/invoke_async/stream/stream_async do not accept per-call event
    #   listeners or listener blocks;
    # - approval notifications share the Agent listener as :approval_required;
    # - Recovery resolution uses resolve/resolve_async.
    module AsyncEventApi
      def invoke(
        input,
        config: {},
        invocation_context: nil,
        **removed_options,
        &removed_block
      )
        _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
        config = _prepare_invocation_config(config, invocation_context)
        _check_event_loop_reentrancy(:invoke, :invoke_async)
        _start_agent_operation(
          input,
          config: config,
          mode: :invoke,
          listener: _phronomy_event_listener
        ).wait_result
      end

      def invoke_async(
        input,
        config: {},
        invocation_context: nil,
        **removed_options,
        &removed_block
      )
        _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
        config = _prepare_invocation_config(config, invocation_context)
        _start_agent_operation(
          input,
          config: config,
          mode: :invoke,
          listener: _phronomy_event_listener
        )
      end

      def stream(
        input,
        config: {},
        invocation_context: nil,
        **removed_options,
        &removed_block
      )
        _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
        listener = _required_stream_listener!(:stream)
        config = _prepare_invocation_config(config, invocation_context)
        _check_event_loop_reentrancy(:stream, :stream_async)
        _start_agent_operation(
          input,
          config: config,
          mode: :stream,
          listener: listener
        ).wait_result
      end

      def stream_async(
        input,
        config: {},
        invocation_context: nil,
        **removed_options,
        &removed_block
      )
        _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
        listener = _required_stream_listener!(:stream_async)
        config = _prepare_invocation_config(config, invocation_context)
        _start_agent_operation(
          input,
          config: config,
          mode: :stream,
          listener: listener
        )
      end

      def approve(execution_id, approval_request_id:, approved: true, config: {})
        _check_event_loop_reentrancy(:approve, :approve_async)
        approve_async(
          execution_id,
          approval_request_id: approval_request_id,
          approved: approved,
          config: config
        ).wait_result
      end

      def approve_async(execution_id, approval_request_id:, approved: true, config: {})
        _reject_removed_generic_identity_keys!(config)
        owner = Phronomy::Runtime.instance.__agent_execution_owner(execution_id)
        coordinator = if owner&.agent&.equal?(self)
          owner.coordinator
        else
          execution_coordinator_for(config)
        end
        coordinator.resume(
          execution_id,
          approval_request_id: approval_request_id,
          approved: approved,
          config: config
        )
      end

      def resolve(
        execution_id,
        expected_execution_revision:,
        subject:,
        outcome:,
        result: Phronomy::Recovery::MISSING,
        error: Phronomy::Recovery::MISSING
      )
        _check_event_loop_reentrancy(:resolve, :resolve_async)
        resolve_async(
          execution_id,
          expected_execution_revision: expected_execution_revision,
          subject: subject,
          outcome: outcome,
          result: result,
          error: error
        ).wait_result
      end

      def resolve_async(
        execution_id,
        expected_execution_revision:,
        subject:,
        outcome:,
        result: Phronomy::Recovery::MISSING,
        error: Phronomy::Recovery::MISSING
      )
        Phronomy::Agent::RecoveryCoordinator.new(self).resolve(
          execution_id,
          expected_execution_revision: expected_execution_revision,
          subject: subject,
          outcome: outcome,
          result: result,
          error: error
        )
      end

      private

      # Framework-private execution-local event routing. This is intentionally
      # not a public compatibility path for invoke_async(..., on_event:).
      def __invoke_async_with_event_sink(
        input,
        on_event:, config: {},
        invocation_context: nil
      )
        raise ArgumentError, "on_event is required" unless on_event

        config = _prepare_invocation_config(config, invocation_context)
        _start_agent_operation(
          input,
          config: config,
          mode: :invoke,
          listener: on_event
        )
      end

      def _start_agent_operation(input, config:, mode:, listener:)
        config = _snapshot_durable_context(config)
        approval = _approval_configuration_snapshot(nil)
        execution_coordinator_for(config).start(
          input,
          config: config.merge(phronomy_recovery_mode: mode.to_sym),
          mode: mode,
          approval_policy: approval[:policy],
          approval_listener: nil,
          on_event: listener
        )
      end

      def _snapshot_durable_context(config)
        return config unless config.key?(:durable_context)

        value = config[:durable_context]
        unless value.is_a?(Hash)
          raise ArgumentError,
            "config[:durable_context] must be a canonical JSON-compatible Hash"
        end

        bytes = Phronomy::CanonicalJSON.dump(value)
        snapshot = Phronomy::Agent::Immutable.copy(
          Phronomy::CanonicalJSON.load(bytes)
        )
        config.merge(durable_context: snapshot)
      end

      def _required_stream_listener!(method_name)
        listener = _phronomy_event_listener
        return listener if listener

        raise ArgumentError,
          "#{method_name} requires an Agent on_event listener registered at new/create/load"
      end

      def _reject_removed_invocation_listener_arguments!(options, block)
        if block
          raise ArgumentError,
            "invoke/stream blocks no longer register Agent events; register the listener at new/create/load"
        end
        return if options.empty?

        removed = options.keys.map(&:inspect).join(", ")
        raise ArgumentError,
          "removed per-invocation Agent option(s): #{removed}; register on_event at new/create/load"
      end

      def execution_coordinator
        @execution_coordinator ||= Agent::ExecutionCoordinator.new(self)
      end

      def execution_coordinator_for(config)
        multi_agent = config.key?(:phronomy_handoff_bindings) ||
          config.key?(:phronomy_handoff_context)
        return execution_coordinator unless multi_agent

        @multi_agent_execution_coordinator ||=
          Phronomy::MultiAgent::ExecutionCoordinator.new(self)
      end
    end
  end
end
