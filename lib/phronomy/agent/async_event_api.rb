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
      def start_reserved_async(reservation:, input:, config: {}, output_schema: nil, schema_delivery: nil)
        __with_operation(async: true) do
          unless reservation.is_a?(ReservedExecution) && reservation.agent_id == agent_id
            raise ArgumentError, "reservation must belong to this Agent"
          end
          config = __invocation_config(_prepare_output_config(config, nil, output_schema, schema_delivery))
          ExactExecution.start(agent: self, execution_id: reservation.execution_id, input: input,
            config: config.merge(phronomy_reservation: reservation.correlation))
        end
      end

      def resume_async(execution_id, config: {})
        __with_operation(async: true) do
          config = __invocation_config(_prepare_invocation_config(config, nil))
          ExactExecution.start(agent: self, execution_id: execution_id, input: nil, config: config, resume_only: true)
        end
      end

      def resume(execution_id, config: {})
        __with_operation do
          _check_event_loop_reentrancy(:resume, :resume_async)
          resume_async(execution_id, config: config).wait_result
        end
      end

      def cancel_async(execution_id)
        __with_operation(async: true) do
          __assert_live_agent!
          environment = __execution_environment
          environment.submit(on_full: :raise) do
            requested = persistence.request_cancellation(agent_id: agent_id, execution_id: execution_id)
            ExecutionCancellation.signal(execution_id, agent_id, environment: environment) if requested
            persistence.observe_execution(agent_id: agent_id, execution_id: execution_id)
          end
        end
      end

      def invoke(
        input,
        config: {},
        invocation_context: nil,
        output_schema: nil,
        schema_delivery: nil,
        **removed_options,
        &removed_block
      )
        __with_operation do
          _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
          config = _prepare_output_config(config, invocation_context, output_schema, schema_delivery)
          _check_event_loop_reentrancy(:invoke, :invoke_async)
          _start_agent_operation(
            input,
            config: config,
            mode: :invoke,
            listener: _phronomy_event_listener
          ).wait_result
        end
      end

      def invoke_async(
        input,
        config: {},
        invocation_context: nil,
        output_schema: nil,
        schema_delivery: nil,
        **removed_options,
        &removed_block
      )
        __with_operation(async: true) do
          _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
          config = _prepare_output_config(config, invocation_context, output_schema, schema_delivery)
          _start_agent_operation(
            input,
            config: config,
            mode: :invoke,
            listener: _phronomy_event_listener
          )
        end
      end

      def stream(
        input,
        config: {},
        invocation_context: nil,
        output_schema: nil,
        schema_delivery: nil,
        **removed_options,
        &removed_block
      )
        __with_operation do
          _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
          listener = _required_stream_listener!(:stream)
          config = _prepare_output_config(config, invocation_context, output_schema, schema_delivery)
          _check_event_loop_reentrancy(:stream, :stream_async)
          _start_agent_operation(
            input,
            config: config,
            mode: :stream,
            listener: listener
          ).wait_result
        end
      end

      def stream_async(
        input,
        config: {},
        invocation_context: nil,
        output_schema: nil,
        schema_delivery: nil,
        **removed_options,
        &removed_block
      )
        __with_operation(async: true) do
          _reject_removed_invocation_listener_arguments!(removed_options, removed_block)
          listener = _required_stream_listener!(:stream_async)
          config = _prepare_output_config(config, invocation_context, output_schema, schema_delivery)
          _start_agent_operation(
            input,
            config: config,
            mode: :stream,
            listener: listener
          )
        end
      end

      def approve(execution_id, approval_request_id:, approved: true, config: {})
        __with_operation do
          _check_event_loop_reentrancy(:approve, :approve_async)
          approve_async(
            execution_id,
            approval_request_id: approval_request_id,
            approved: approved,
            config: config
          ).wait_result
        end
      end

      def approve_async(execution_id, approval_request_id:, approved: true, config: {})
        __with_operation(async: true) do
          config = _prepare_invocation_config(config, nil)
          owner = __execution_environment.existing_registry&.agent_execution_owner(execution_id)
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
      end

      def resolve(
        execution_id,
        expected_execution_revision:,
        subject:,
        outcome:,
        result: Phronomy::Agent::RecoveryRules::MISSING,
        error: Phronomy::Agent::RecoveryRules::MISSING
      )
        __with_operation do
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
      end

      def resolve_async(
        execution_id,
        expected_execution_revision:,
        subject:,
        outcome:,
        result: Phronomy::Agent::RecoveryRules::MISSING,
        error: Phronomy::Agent::RecoveryRules::MISSING
      )
        __with_operation(async: true) do
          Phronomy::Agent::RecoveryCoordinator.new(self).resolve(
            execution_id,
            expected_execution_revision: expected_execution_revision,
            subject: subject,
            outcome: outcome,
            result: result,
            error: error
          )
        end
      end

      private

      def _prepare_output_config(config, invocation_context, schema, schema_delivery)
        config = _prepare_invocation_config(config, invocation_context)
        if schema.nil?
          raise ArgumentError, "schema_delivery requires output_schema" unless schema_delivery.nil?
          return config
        end
        contract = OutputContract.new(schema, schema_delivery: schema_delivery.nil? ? :native : schema_delivery)
        config.merge(phronomy_output_contract: contract)
      end

      def _start_agent_operation(input, config:, mode:, listener:)
        config = __invocation_config(_snapshot_durable_context(config))
        @_phronomy_execution_wiring = config.dup.freeze
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
        snapshot = Phronomy::Values::Immutable.copy(
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

      def execution_coordinator_for(_config) = execution_coordinator
    end
  end
end
