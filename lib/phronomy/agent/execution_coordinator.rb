# frozen_string_literal: true

require "time"

module Phronomy
  module Agent
    class ExecutionCoordinator
      Prepared = Data.define(:execution, :runtime_projection, :filtered_input, :config)
      AgentTerminalCommand = Struct.new(:coordinator, :activation, :result_task, :outcome, :commit_error)
      PrepFailureCommand = Struct.new(:coordinator, :on_event_listener, :result_task, :error)

      def initialize(agent)
        @agent = agent
      end

      def start(
        input, config: {}, mode: :invoke,
        approval_policy: nil, approval_listener: nil, on_event: nil
      )
        @agent.send(:_reject_removed_generic_identity_keys!, config)
        result_task = Phronomy::Task.deferred(name: "agent-#{@agent.agent_id}-#{mode}")
        runtime = Phronomy::Runtime.instance
        preparation = runtime.offload.submit(on_full: :raise) do
          prepare(input, config: config)
        end
        preparation.on_complete do |prepared, error|
          if error
            post_prep_failure(runtime, on_event, result_task, translated(error))
          else
            register(
              prepared,
              result_task,
              mode: mode,
              approval_policy: approval_policy,
              approval_listener: approval_listener,
              on_event: on_event
            )
          end
        end
        result_task
      rescue => error
        if defined?(runtime) && runtime
          post_prep_failure(runtime, on_event, result_task, translated(error))
        else
          fail_task(result_task, translated(error))
        end
        result_task
      end

      def resume(
        execution_id,
        approval_request_id:,
        approved:,
        config: {}
      )
        @agent.send(:_reject_removed_generic_identity_keys!, config)
        result_task = Phronomy::Task.deferred(
          name: "agent-approval-resume:#{execution_id}"
        )
        runtime = Phronomy::Runtime.instance
        activation = runtime.__agent_activations.fetch(execution_id)
        unless activation
          fail_task(
            result_task,
            Phronomy::ExecutionRehydrationRequiredError.new(
              "no live activation for #{execution_id}; durable rehydration is required"
            )
          )
          return result_task
        end

        unless activation.agent.equal?(@agent) &&
            activation.execution.status == :suspended
          fail_task(
            result_task,
            ArgumentError.new(
              "execution is not a suspended execution of this agent: #{execution_id}"
            )
          )
          return result_task
        end

        preparation = runtime.offload.submit(on_full: :raise) do
          mark_resuming!(
            activation,
            approval_request_id: approval_request_id,
            approved: approved
          )
          activation
        end
        preparation.on_complete do |prepared_activation, error|
          if error
            fail_task(result_task, translated(error))
            next
          end

          begin
            start_resume(
              prepared_activation,
              result_task,
              approved: approved,
              config: config
            )
          rescue => start_error
            commit = runtime.offload.submit(on_full: :raise) do
              commit_failed(
                prepared_activation,
                prepared_activation.invocation,
                start_error
              )
            end
            commit.on_complete do |terminal, commit_error|
              if commit_error
                fail_task(result_task, commit_error)
              else
                runtime.__agent_activations.delete(execution_id)
                fail_task(result_task, terminal.fetch(:error))
              end
            end
          end
        end
        result_task
      rescue => error
        fail_task(result_task, translated(error)) if result_task
        result_task
      end

      # Persists facts from the previous Provider/Tool cycle and fixes the next
      # Manifest from the current local Agent state. This runs on OffloadPool.
      def prepare_next_llm_call(activation)
        snapshot = activation.runtime_snapshot
        root = @agent.agent_root
        current = activation.execution
        journal_records = @agent.send(:_journal_records_snapshot)
        manifest = manifest_ref = updated = nil

        @agent.persistence.transaction do |tx|
          assert_local_durable_base!(tx, root)
          encoded_records, call_records = encode_runtime_records(
            activation,
            tx: tx,
            snapshot: snapshot,
            context_candidate: true,
            agent_root: root
          )
          staged = current.with(
            execution_revision: current.execution_revision,
            phase: :preparing_llm_call,
            working_records: current.working_records + encoded_records,
            llm_calls: current.llm_calls + call_records
          )
          invocation_config = activation.invocation&.config || {}
          patch = @agent.send(
            :run_before_llm_input_hooks,
            call_sequence: staged.llm_calls.length + 1,
            config: invocation_config
          )
          manifest, manifest_ref = ContextAssembler.new(
            agent: @agent,
            persistence: tx,
            policy: context_policy_for(staged),
            journal_records: journal_records
          ).build_followup(
            base_manifest: activation.base_manifest,
            agent_root: root,
            execution: staged,
            config: invocation_config,
            patch: patch
          )
          refs = Array(staged.metadata["manifest_refs"]) + [manifest_ref]
          updated = staged.with(
            phase: :calling_llm,
            metadata: staged.metadata.merge(
              "manifest_ref" => manifest_ref,
              "manifest_refs" => refs
            )
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: updated
          )
        end

        activation.replace_execution(updated)
        activation.acknowledge_runtime_snapshot(snapshot)

        projection = RubyLLMMaterializer.new(
          agent: @agent,
          persistence: @agent.persistence
        ).materialize(manifest: manifest, manifest_ref: manifest_ref)
        activation.replace_runtime_projection(projection)
        projection
      end

      def prepare(input, config:)
        raw_message = @agent.send(:extract_message, input)
        execution, active_root = admit_execution(raw_message)
        @agent.__replace_root(active_root)
        current_execution = execution

        begin
          effective_config = config
          @agent.send(
            :check_cancellation!,
            effective_config,
            "invocation cancelled before input filtering"
          )
          filtered_input = @agent.send(:run_input_filters!, input)
          @agent.send(
            :check_cancellation!,
            effective_config,
            "invocation cancelled before context assembly"
          )
          filtered_message = @agent.send(:extract_message, filtered_input)
          manifest = manifest_ref = active_execution = nil
          local_journal = @agent.send(:_journal_records_snapshot)

          @agent.persistence.transaction do |tx|
            assert_local_durable_base!(tx, active_root)
            filtered_ref = tx.contents.put_text(filtered_message)
            input_record = JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: current_execution.execution_id,
              kind: :external_message,
              channel: :external,
              role: :user,
              content_ref: filtered_ref,
              context_generation: active_root.transcript_generation,
              context_candidate: true
            )
            staged = current_execution.with(
              execution_revision: current_execution.execution_revision,
              working_records: current_execution.working_records + [input_record],
              metadata: current_execution.metadata.merge(
                "current_input_ref" => filtered_ref,
                "current_input_record_id" => input_record.record_id
              )
            )
            manifest, manifest_ref = ContextAssembler.new(
              agent: @agent,
              persistence: tx,
              policy: context_policy_for(staged),
              journal_records: local_journal
            ).build_initial(
              input: filtered_input,
              agent_root: active_root,
              execution: staged,
              config: effective_config,
              patch: @agent.send(
                :run_before_llm_input_hooks,
                call_sequence: 1,
                config: effective_config
              )
            )
            active_execution = staged.with(
              status: :active,
              phase: :calling_llm,
              metadata: staged.metadata.merge(
                "base_manifest_ref" => manifest_ref,
                "manifest_ref" => manifest_ref,
                "manifest_refs" => [manifest_ref]
              )
            )
            tx.executions.save(
              current_execution.execution_id,
              expected_revision: current_execution.execution_revision,
              execution: active_execution
            )
          end
          current_execution = active_execution

          projection = RubyLLMMaterializer.new(
            agent: @agent,
            persistence: @agent.persistence
          ).materialize(manifest: manifest, manifest_ref: manifest_ref)
          Phronomy::Agent::ExecutionCoordinator::Prepared.new(
            execution: active_execution,
            runtime_projection: projection,
            filtered_input: filtered_input,
            config: effective_config
          )
        rescue => error
          commit_preparation_failure(current_execution, error)
          raise
        end
      end

      def admit_execution(raw_message)
        root = @agent.agent_root
        raise Phronomy::Error, "agent is closed: #{@agent.agent_id}" if root.lifecycle_status == :closed

        execution = next_root = nil
        @agent.persistence.transaction do |tx|
          input_ref = tx.contents.put_text(raw_message)
          input_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            kind: :input_received,
            channel: :external,
            role: :user,
            content_ref: input_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          policy_descriptor = ContextPolicies::Default.new.descriptor
          execution = AgentExecution.start(
            agent_root: root,
            input_record: input_record,
            metadata: {
              "current_input_ref" => input_ref,
              "context_policy" => policy_descriptor.to_h
            }.compact
          )
          input_record = JournalRecord.from_h(
            input_record.to_h.merge("execution_id" => execution.execution_id)
          )
          execution = execution.with(
            execution_revision: 0,
            working_records: [input_record]
          )
          tx.executions.create_active(execution)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            lifecycle_status: :active
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        [execution, next_root]
      end

      def commit_preparation_failure(execution, error)
        translated_error = translated(error)
        root = @agent.agent_root
        failed = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          error_ref = tx.contents.put_json(
            "class" => translated_error.class.name,
            "message" => translated_error.message
          )
          audit_records = execution.working_records.map do |record|
            JournalRecord.from_h(
              record.to_h.merge("context_candidate" => false)
            )
          end
          terminal_status = terminal_status_for(translated_error)
          audit_records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: execution.execution_id,
            kind: execution_terminal_kind(terminal_status),
            channel: :audit,
            content_ref: error_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: audit_records
          )
          failed = execution.with(
            status: terminal_status,
            phase: terminal_status,
            working_records: [],
            error_ref: error_ref,
            terminal_reason: translated_error.class.name
          )
          tx.executions.save(
            execution.execution_id,
            expected_revision: execution.execution_revision,
            execution: failed
          )
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        @agent.send(:_append_journal_records, appended)
        @agent.__replace_root(next_root)
        failed
      end

      def register(prepared, result_task, mode:, approval_policy:, approval_listener:, on_event:)
        activation = AgentExecutionActivation.new(
          execution: prepared.execution,
          agent: @agent,
          runtime_projection: prepared.runtime_projection,
          coordinator: self,
          application_listener: on_event
        )
        runtime = Phronomy::Runtime.instance
        runtime.__agent_activations.register(activation)
        event_loop = runtime.event_loop
        effective_config = prepared.config.merge(
          phronomy_activation: activation,
          phronomy_runtime_projection: prepared.runtime_projection,
          phronomy_filtered_input: prepared.filtered_input,
          execution_id: prepared.execution.execution_id
        )
        session = Agent::AgentInvocationSessionBuilder.build(
          agent: @agent,
          input: prepared.filtered_input,
          config: effective_config,
          approval_policy: approval_policy,
          approval_listener: approval_listener,
          mode: mode,
          on_event: ->(event) { activation.record_event(event) },
          runtime: runtime
        )
        activation.invocation = session.context
        activation.session = session
        source_task = Phronomy::Task.deferred(name: "#{result_task.name}-source")
        source_task.on_complete do |invocation, error|
          finish(
            activation,
            result_task,
            invocation || session.context,
            error
          )
        end
        event_loop.register(session, completion: source_task)
      rescue => error
        activation ||= AgentExecutionActivation.new(
          execution: prepared.execution,
          agent: @agent,
          runtime_projection: prepared.runtime_projection,
          coordinator: self,
          application_listener: on_event
        )
        finish(activation, result_task, activation.invocation, error)
      end

      def finish(activation, result_task, invocation, error)
        runtime = Phronomy::Runtime.instance
        operation = runtime.offload.submit(on_full: :raise) do
          compute_terminal(activation, invocation, error)
        end
        operation.on_complete do |outcome, commit_error|
          command = AgentTerminalCommand.new(
            self, activation, result_task, outcome, commit_error
          )
          posted = runtime.event_loop.post(
            Phronomy::Event.new(
              type: :agent_terminal_ready,
              target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
              payload: {command: command}
            )
          )
          unless posted
            settle_without_listener(
              activation, result_task, outcome, commit_error
            )
          end
        end
      rescue => caught
        fail_task(result_task, translated(caught))
      end

      public

      def deliver_on_event_loop(command)
        case command
        when PrepFailureCommand
          callback_error = @agent.send(
            :_deliver_stream_event,
            command.on_event_listener,
            StreamEvent.new(
              type: terminal_event_type(command.error),
              payload: {error: command.error}
            )
          )
          settle_after_terminal(
            command.result_task,
            callback_error,
            terminal_event_type(command.error),
            nil,
            command.error
          )
        when AgentTerminalCommand
          deliver_execution_terminal(command)
        else
          raise Phronomy::Error, "unknown terminal command: #{command.class}"
        end
      end

      private

      def compute_terminal(activation, invocation, error)
        if (failure = activation.callback_failure)
          terminal = commit_failed(
            activation,
            invocation,
            failure.to_stream_callback_error
          )
          return {type: :failed, error: terminal.fetch(:error)}
        end
        if error
          terminal = commit_failed(activation, invocation, error)
          return {type: :failed, error: terminal.fetch(:error)}
        end
        if invocation&.phase == :suspended
          return {
            type: :suspended,
            result: commit_suspended(activation, invocation)
          }
        end
        raise invocation.block_error if invocation.input_blocked? || invocation.output_blocked?
        raise invocation.error if invocation.error

        {type: :completed, result: commit_completed(activation, invocation)}
      rescue => caught
        terminal = commit_failed(activation, invocation, caught)
        {type: :failed, error: terminal.fetch(:error)}
      end

      def commit_suspended(activation, invocation)
        current = activation.execution
        root = @agent.agent_root
        request = invocation.approval_request
        runtime_snapshot = activation.runtime_snapshot
        suspended = next_root = nil

        @agent.persistence.transaction do |tx|
          encoded_records, call_records = encode_runtime_records(
            activation,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: true,
            agent_root: root
          )
          request_ref = tx.contents.put_json(json_value(request.to_h))
          approval_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: :approval_required,
            channel: :approval,
            content_ref: request_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          suspended = current.with(
            status: :suspended,
            phase: :approval,
            working_records: current.working_records + encoded_records + [approval_record],
            llm_calls: current.llm_calls + call_records,
            approval_request: json_value(request.to_h)
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: suspended
          )
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            lifecycle_status: :suspended
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        activation.acknowledge_runtime_snapshot(runtime_snapshot)
        activation.replace_execution(suspended)
        @agent.__replace_root(next_root)
        dispatch_approval_listener(invocation, request)
        result_base(suspended, next_root).merge(
          suspended: true,
          approval_request: request
        )
      end

      def commit_completed(activation, invocation)
        current = activation.execution
        root = @agent.agent_root
        runtime_snapshot = activation.runtime_snapshot
        completed = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          encoded_records, call_records = encode_runtime_records(
            activation,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: true,
            agent_root: root
          )
          output_ref = tx.contents.put_text(invocation.output.to_s)
          final_output_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: :final_output,
            channel: :audit,
            role: :assistant,
            content_ref: output_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          completed_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: invocation.rejected ? :execution_rejected : :execution_completed,
            channel: :audit,
            content_ref: output_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          all_records = current.working_records + encoded_records +
            [final_output_record, completed_record]
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: all_records
          )
          completed = current.with(
            status: invocation.rejected ? :rejected : :completed,
            phase: :completed,
            working_records: [],
            llm_calls: current.llm_calls + call_records,
            approval_request: nil,
            result_ref: output_ref,
            terminal_reason: invocation.rejected ? "rejected" : "completed"
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: completed
          )
          context_changed = appended.any?(&:context_candidate)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + (context_changed ? 1 : 0),
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        activation.acknowledge_runtime_snapshot(runtime_snapshot)
        activation.replace_execution(completed)
        @agent.send(:_append_journal_records, appended)
        @agent.__replace_root(next_root)
        result_base(completed, next_root).merge(
          output: invocation.output,
          rejected: invocation.rejected || nil,
          usage: invocation.usage,
          messages: transcript_messages(next_root)
        ).compact
      end

      def commit_failed(activation, _invocation, error)
        translated_error = translated(error)
        current = activation.execution
        root = @agent.agent_root
        runtime_snapshot = activation.runtime_snapshot
        failed = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          encoded_records, call_records = encode_runtime_records(
            activation,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: false,
            agent_root: root
          )
          error_ref = tx.contents.put_json(
            "class" => translated_error.class.name,
            "message" => translated_error.message
          )
          audit_records = (current.working_records + encoded_records).map do |record|
            JournalRecord.from_h(
              record.to_h.merge("context_candidate" => false)
            )
          end
          terminal_status = terminal_status_for(translated_error)
          audit_records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: execution_terminal_kind(terminal_status),
            channel: :audit,
            content_ref: error_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: audit_records
          )
          failed = current.with(
            status: terminal_status,
            phase: terminal_status,
            working_records: [],
            llm_calls: current.llm_calls + call_records,
            error_ref: error_ref,
            terminal_reason: translated_error.class.name
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: failed
          )
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        activation.acknowledge_runtime_snapshot(runtime_snapshot)
        activation.replace_execution(failed)
        @agent.send(:_append_journal_records, appended)
        @agent.__replace_root(next_root)
        {error: translated_error, execution: failed, root: next_root}
      end

      def encode_runtime_records(
        activation,
        tx:,
        snapshot:,
        context_candidate:,
        agent_root:
      )
        execution = activation.execution
        root = agent_root
        records = []
        calls = []

        snapshot.fetch(:llm_results).each_with_index do |item, index|
          outcome = item[:response]
          error = item[:error]
          llm_call_id = item.fetch(:llm_call_id).to_s
          intercepted = error.is_a?(ToolCallIntercepted)
          call_error = intercepted ? nil : error
          output_ref = assistant_output_ref(tx, outcome)
          assistant_ref = assistant_message_ref(tx, outcome)
          error_ref = if call_error
            tx.contents.put_json(
              "class" => call_error.class.name,
              "message" => call_error.message
            )
          end
          usage_ref = if outcome && !outcome.usage.empty?
            tx.contents.put_json(json_value(outcome.usage))
          end
          call = LLMCallRecord.new(
            llm_call_id: llm_call_id,
            execution_id: execution.execution_id,
            sequence: execution.llm_calls.length + index + 1,
            status: call_error ? :failed : :completed,
            manifest_ref: item.fetch(:manifest_ref),
            output_ref: output_ref,
            error_ref: error_ref,
            usage_ref: usage_ref,
            started_at: item.fetch(:started_at),
            completed_at: Time.now.utc.iso8601(6),
            metadata: {
              "streaming" => item[:streaming],
              "tool_call_intercepted" => intercepted,
              "assistant_outcome_captured" => !outcome.nil?,
              "tool_call_count" => outcome ? outcome.tool_calls.length : 0
            }
          )
          calls << call
          call_ref = tx.contents.put_json(call.to_h)
          records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: execution.execution_id,
            llm_call_id: llm_call_id,
            kind: :llm_call_recorded,
            channel: :audit,
            content_ref: call_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )

          if assistant_ref
            records << JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :assistant_message,
              channel: :llm,
              role: :assistant,
              content_ref: assistant_ref,
              context_generation: root.transcript_generation,
              context_candidate: context_candidate,
              metadata: assistant_message_metadata(outcome)
            )
          end
        end

        if (active = snapshot[:active_call])
          abandoned = LLMCallRecord.new(
            llm_call_id: active.fetch(:llm_call_id),
            execution_id: execution.execution_id,
            sequence: execution.llm_calls.length + calls.length + 1,
            status: :cancelled,
            manifest_ref: active.fetch(:manifest_ref),
            started_at: active.fetch(:started_at),
            completed_at: Time.now.utc.iso8601(6),
            metadata: {
              "reason" => "execution_terminalized_before_provider_settlement"
            }
          )
          calls << abandoned
          records << JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: execution.execution_id,
            llm_call_id: abandoned.llm_call_id,
            kind: :llm_call_recorded,
            channel: :audit,
            content_ref: tx.contents.put_json(abandoned.to_h),
            context_generation: root.transcript_generation,
            context_candidate: false
          )
        end

        snapshot.fetch(:runtime_events).each do |event|
          case event.type
          when :tool_call
            next
          when :tool_result
            payload = event.payload
            llm_call_id = payload[:llm_call_id] || payload["llm_call_id"]
            tool_call_id = payload.fetch(:tool_call_id).to_s
            tool_name = payload.fetch(:tool_name).to_s
            result_ref = put_runtime_content(tx, payload.fetch(:tool_result))
            records << JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :tool_result,
              channel: :tool,
              content_ref: result_ref,
              causation_id: tool_call_id,
              context_generation: root.transcript_generation,
              context_candidate: false,
              metadata: {
                "tool_call_id" => tool_call_id,
                "tool_name" => tool_name
              }
            )

            message_payload = if payload.key?(:tool_message)
              payload.fetch(:tool_message)
            else
              payload.fetch("tool_message")
            end
            records << JournalRecord.new(
              agent_id: @agent.agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :tool_message,
              channel: :tool,
              role: :tool,
              content_ref: tx.contents.put_json(json_value(message_payload)),
              causation_id: tool_call_id,
              context_generation: root.transcript_generation,
              context_candidate: context_candidate,
              metadata: {
                "tool_call_id" => tool_call_id,
                "tool_name" => tool_name
              }
            )
          end
        end
        [records, calls]
      end

      def mark_resuming!(activation, approval_request_id:, approved:)
        current = activation.execution
        current_root = @agent.agent_root
        unless current.agent_id == @agent.agent_id && current.status == :suspended
          raise ArgumentError, "execution is not suspended: #{current.execution_id}"
        end

        request = current.approval_request || {}
        request_id = request["id"] || request[:id]
        unless request_id.to_s == approval_request_id.to_s
          raise ArgumentError,
            "approval request does not match execution #{current.execution_id}"
        end

        updated = next_root = nil
        @agent.persistence.transaction do |tx|
          decision_ref = tx.contents.put_json(
            "approval_request_id" => request_id.to_s,
            "approved" => !!approved
          )
          decision_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            kind: :approval_decided,
            channel: :approval,
            content_ref: decision_ref,
            context_generation: current_root.transcript_generation,
            context_candidate: false
          )
          updated = current.with(
            status: :active,
            phase: :resuming,
            working_records: current.working_records + [decision_record],
            approval_request: request.merge("approved" => approved)
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: updated
          )
          next_root = current_root.with(
            agent_revision: current_root.agent_revision + 1,
            lifecycle_status: :active
          )
          tx.agents.save(
            current_root.agent_id,
            expected_revision: current_root.agent_revision,
            root: next_root
          )
        end
        activation.replace_execution(updated)
        @agent.__replace_root(next_root)
        updated
      end

      def assert_local_durable_base!(tx, root)
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: root.agent_revision,
          journal_position: root.journal_position
        )
      end

      def transcript_messages(root)
        materializer = RubyLLMMaterializer.new(
          agent: @agent,
          persistence: @agent.persistence
        )
        materializer.materialize_journal_records(
          JournalProjection.new(
            agent_root: root,
            records: @agent.send(:_journal_records_snapshot)
          ).transcript_records
        )
      end

      def deliver_execution_terminal(command)
        activation = command.activation
        registry = Phronomy::Runtime.instance.__agent_activations
        if command.commit_error
          callback_error = deliver_terminal(
            activation,
            :error,
            error: command.commit_error
          )
          settle_after_terminal(
            command.result_task,
            callback_error,
            :error,
            nil,
            command.commit_error
          )
          return
        end

        outcome = command.outcome
        case outcome.fetch(:type)
        when :suspended
          result = outcome.fetch(:result)
          callback_error = deliver_terminal(
            activation,
            :approval_required,
            request: result.fetch(:approval_request)
          )
          settle_after_terminal(
            command.result_task,
            callback_error,
            :approval_required,
            result
          )
        when :completed
          registry.delete(activation.execution_id)
          result = outcome.fetch(:result)
          callback_error = deliver_terminal(activation, :done, result)
          settle_after_terminal(
            command.result_task,
            callback_error,
            :done,
            result
          )
        when :failed
          registry.delete(activation.execution_id)
          error = outcome.fetch(:error)
          type = terminal_event_type(error)
          callback_error = deliver_terminal(activation, type, error: error)
          settle_after_terminal(
            command.result_task,
            callback_error,
            type,
            nil,
            error
          )
        end
      end

      def settle_without_listener(activation, result_task, outcome, commit_error)
        registry = Phronomy::Runtime.instance.__agent_activations
        if commit_error
          return fail_task(result_task, commit_error)
        end

        case outcome&.fetch(:type)
        when :suspended
          complete_task(result_task, outcome.fetch(:result))
        when :completed
          registry.delete(activation.execution_id)
          complete_task(result_task, outcome.fetch(:result))
        when :failed
          registry.delete(activation.execution_id)
          fail_task(result_task, outcome.fetch(:error))
        else
          registry.delete(activation.execution_id)
          fail_task(
            result_task,
            Phronomy::RuntimeShutdownError.new(
              "EventLoop is not accepting terminal delivery"
            )
          )
        end
      end

      def assistant_message_ref(tx, outcome)
        return unless outcome

        payload = {
          "role" => "assistant",
          "content" => json_value(outcome.content),
          "tool_calls" => json_value(Array(outcome.tool_calls)),
          "model_id" => outcome.metadata["model_id"]
        }.compact
        tx.contents.put_json(payload)
      end

      def assistant_message_metadata(outcome)
        calls = Array(outcome&.tool_calls)
        {
          "tool_call_ids" => calls.map { |call| call.fetch("id").to_s },
          "tool_names" => calls.map { |call| call.fetch("name").to_s }
        }
      end

      def assistant_output_ref(tx, outcome)
        return unless outcome&.content_present?

        content = outcome.content
        text = content.is_a?(String) ? content : Phronomy::CanonicalJSON.dump(content)
        tx.contents.put_text(text)
      end

      def put_runtime_content(tx, value)
        value.is_a?(String) ?
          tx.contents.put_text(value) : tx.contents.put_json(json_value(value))
      end

      def start_resume(activation, result_task, approved:, config:)
        invocation = activation.invocation
        invocation.merge_config!(config)
        invocation.begin_approval_resume!(approved: approved)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        parent_session = Agent::AgentInvocationSessionBuilder.build_for_resume(
          agent_invocation: invocation,
          resume_event: :resume,
          resume_phase: :suspended,
          runtime: runtime
        )
        activation.session = parent_session
        source_task = Phronomy::Task.deferred(name: "#{result_task.name}-source")
        source_task.on_complete do |completed, error|
          finish(
            activation,
            result_task,
            completed || parent_session.context,
            error
          )
        end
        event_loop.register(parent_session, completion: source_task)
        invocation.tool_invocations.each do |child|
          child_session = if child.awaiting_approval?
            Agent::ToolInvocationSessionBuilder.build_for_resume(
              tool_invocation: child,
              resume_event: approved ? :approve : :reject,
              resume_phase: :awaiting_approval,
              runtime: runtime
            )
          elsif !approved && child.authorized?
            Agent::ToolInvocationSessionBuilder.build_for_resume(
              tool_invocation: child,
              resume_event: :cancel,
              resume_phase: :authorized,
              runtime: runtime
            )
          end
          register_child(event_loop, runtime, child, child_session) if child_session
        end
      end

      def register_child(event_loop, runtime, child, session)
        completion = Phronomy::Task.deferred(name: "tool-session:#{child.id}")
        completion.on_complete do |_result, error|
          next unless error

          child.mark_framework_failed!(error)
          runtime.event_loop.post_to_session(
            Phronomy::Event.new(
              type: :tool_failed,
              target_id: child.parent_agent_invocation_id,
              payload: {tool_invocation_id: child.id}
            )
          )
        end
        event_loop.register(session, completion: completion)
      end

      def result_base(execution, root)
        {
          agent_id: root.agent_id,
          execution_id: execution.execution_id,
          agent_revision: root.agent_revision,
          context_revision: root.context_revision,
          journal_position: root.journal_position
        }
      end

      def context_policy_for(execution)
        descriptor_hash = execution.metadata.fetch("context_policy") do
          ContextPolicies::Default.new.descriptor.to_h
        end
        descriptor = ContextPolicyDescriptor.from_h(descriptor_hash)
        ContextPolicyRegistry.default.resolve(descriptor)
      end

      def deliver_terminal(activation, type, payload)
        listener = activation.application_listener
        return nil unless listener

        @agent.send(
          :_deliver_stream_event,
          listener,
          StreamEvent.new(type: type, payload: payload)
        )
      end

      def post_prep_failure(runtime, listener, result_task, error)
        command = PrepFailureCommand.new(self, listener, result_task, error)
        posted = runtime.event_loop.post(
          Phronomy::Event.new(
            type: :agent_terminal_ready,
            target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {command: command}
          )
        )
        fail_task(result_task, error) unless posted
      end

      def settle_after_terminal(
        result_task,
        callback_error,
        event_type,
        result,
        execution_error = nil
      )
        if callback_error
          policy = Phronomy.configuration.stream_callback_error_policy
          @agent.send(
            :_report_stream_callback_error,
            callback_error,
            event: StreamEvent.new(
              type: event_type,
              payload: result || {error: execution_error}
            ),
            invocation_id: nil,
            callback_error_policy: policy
          )
          if policy == :fail_task && execution_error.nil?
            return fail_task(
              result_task,
              @agent.send(
                :_build_stream_callback_error,
                event_type: event_type,
                callback_error: callback_error,
                result: result
              )
            )
          end
        end
        execution_error ?
          fail_task(result_task, execution_error) : complete_task(result_task, result)
      end

      def terminal_event_type(error)
        return :timeout if error.is_a?(Phronomy::TimeoutError)
        return :cancelled if error.is_a?(Phronomy::CancellationError)

        :error
      end

      def dispatch_approval_listener(invocation, request)
        listener = invocation.approval_listener
        return unless listener

        Phronomy::Runtime.instance.offload.submit(on_full: :raise) do
          listener.call(request)
        end
      end

      def json_value(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, json_value(child)] }
        when Array
          value.map { |child| json_value(child) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        when Symbol
          value.to_s
        else
          if value.respond_to?(:to_h)
            json_value(value.to_h)
          else
            raise ArgumentError,
              "unsupported canonical runtime value: #{value.class}"
          end
        end
      end

      def terminal_status_for(error)
        if defined?(Phronomy::CancellationError) &&
            error.is_a?(Phronomy::CancellationError)
          return :cancelled
        end
        if defined?(Phronomy::FilterBlockError) &&
            error.is_a?(Phronomy::FilterBlockError)
          return :blocked
        end

        :failed
      end

      def execution_terminal_kind(status)
        {
          cancelled: :execution_cancelled,
          blocked: :execution_blocked,
          failed: :execution_failed
        }.fetch(status)
      end

      def translated(error)
        @agent.send(:_translated_error, error)
      end

      def complete_task(task, result)
        @agent.send(:_complete_result_task, task, result)
      end

      def fail_task(task, error)
        @agent.send(:_fail_result_task, task, error)
      end
    end
  end
end
