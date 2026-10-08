# frozen_string_literal: true

module Phronomy
  module Agent
    # Limited synchronous participant SPI. Agent owns all record mutations,
    # revision checks and outcome publication. A participant owns its own
    # transaction and passes only an opaque extension and a transfer receipt.
    # @api public
    class ExecutionChange
      attr_reader :kind, :agent_id, :execution_id, :extension, :operations,
        :control_request, :cancel_requested, :recovery_required, :durable_context,
        :correlation, :coordinator

      # Agent execution constructs changes; applications implement participants.
      # @api private
      def initialize(agent:, current:, root:, kind:, updated: nil, terminal: nil, config: {}, &write)
        @agent, @store, @current, @root = agent, agent.persistence, current, root
        @coordinator = @store.coordinator
        @kind, @updated, @write = kind, updated, write
        @agent_id, @execution_id = current.agent_id, current.execution_id
        @extension = current.metadata["execution_extension"] && ExecutionExtensionState.from_h(current.metadata["execution_extension"])
        @correlation = Phronomy::Values::Immutable.copy(current.metadata["reservation"])
        @control_request = terminal&.handoff
        @cancel_requested = terminal&.cancel_requested || false
        error = terminal && (terminal.callback_failure&.to_stream_callback_error || terminal.source_error || terminal.block_error || terminal.invocation_error)
        @control_request = nil if error || terminal&.phase == :suspended
        @recovery_required = error.is_a?(Phronomy::ExecutionRehydrationRequiredError)
        @finishing = kind == :terminal && !@recovery_required && (error || terminal.phase != :suspended)
        @operations = Array(updated&.metadata&.fetch(ExecutionMetadata::TOOL_BATCH_METADATA_KEY, nil)).filter_map do |entry|
          next unless entry.fetch("status") == "authorized"
          Store::AuthorizedOperation.new(invocation_id: entry.fetch("tool_invocation_id"), name: entry.fetch("tool_name"),
            arguments: Phronomy::Values::Immutable.copy(entry.fetch("arguments").compact))
        end.freeze
        ref = current.metadata["durable_context_ref"]
        @durable_context = ref && Phronomy::Values::Immutable.copy(@store.contents.fetch_json(ref))
        @participant = config[:phronomy_execution_participant]
        @thread = Thread.current
        validate_binding!
      end

      def finishing? = !!@finishing

      # Runs current wiring and proves the complete captured change after an
      # ambiguous response. A savepoint never grants publication permission.
      # @api private
      def perform
        raise Phronomy::ConfigurationError, "Execution change is single-use" if @performed
        @performed = true
        perform_once
      end

      # @api private
      def perform_once
        if @participant
          @participant.commit(self)
        else
          coordinator.atomic { |scope|
            prepare_in(scope)
            commit_in(scope)
          }
        end
        unless @scope&.committed? && @result
          raise Phronomy::Persistence::TransactionError, "Execution change has not committed its outer scope"
        end
        @result
      rescue => error
        raise unless @after && @scope&.outermost?
        outcome = Phronomy::Persistence::SaveOutcome.compare(before: @before, after: @after, original_error: error) do
          coordinator.atomic do |scope|
            @participant&.guard_change(self, scope)
            @store.guard_agents(scope, agent_ids: [agent_id])
            snapshot(scope)
          end
        end
        return @result if outcome.disposition == :committed
        raise error if outcome.disposition == :not_committed
        raise Phronomy::ExecutionRehydrationRequiredError, "Execution change outcome is unknown: #{(outcome.read_error || error).message}"
      end

      private :perform_once

      # Capture the complete pre-state after the participant has acquired its
      # ordered guards, before it changes its own records.
      def prepare_in(scope)
        raise Phronomy::Persistence::TransactionError, "Execution change belongs to another thread" unless @thread.equal?(Thread.current)
        raise Phronomy::ConfigurationError, "Execution change is single-use" if @scope
        @store.guard_agents(scope, agent_ids: [agent_id])
        @before = snapshot(scope)
        @cancel_requested ||= @store.cancellation_requested?(agent_id: agent_id, execution_id: execution_id, scope: scope)
        @scope = scope
        nil
      end

      # Must be called once in the participant's original synchronous context.
      # No arbitrary execution setter or callback is exposed to the participant.
      def commit_in(scope, state: extension, transfer_receipt: nil, pending: false)
        raise Phronomy::Persistence::TransactionError, "Execution change belongs to another thread" unless @thread.equal?(Thread.current)
        raise Phronomy::ConfigurationError, "Execution change must use its prepared scope exactly once" unless @scope.equal?(scope) && !@used
        @used = true
        if state && (!extension || state.binding_key != extension.binding_key || state.binding_version != extension.binding_version)
          raise Phronomy::ConfigurationError, "Execution extension identity cannot change"
        end
        raise ArgumentError, "dispatch cannot choose a terminal outcome" if kind == :dispatch && (transfer_receipt || pending)
        raise ArgumentError, "only a control request can transfer responsibility" if transfer_receipt && !control_request
        raise ArgumentError, "pending work requires cancellation or recovery" if pending && !(cancel_requested || recovery_required)
        @store.participate(scope) do |records|
          records.assert_agent_watermark!(agent_id: agent_id, agent_revision: @root.agent_revision, journal_position: @root.journal_position)
          observed = records.executions.load(execution_id)
          unless observed.agent_id == agent_id && observed.execution_revision == @current.execution_revision
            raise Phronomy::Persistence::StateConflictError, "Execution changed before participation"
          end
          if kind == :dispatch
            updated = attach_state(@updated, state)
            records.executions.save(execution_id, expected_revision: @current.execution_revision, execution: updated)
            @result = updated
          else
            @result = @write.call(records, state, transfer_receipt, pending)
          end
        end
        @after = snapshot(scope)
        nil
      end

      # Finalized input material; policies are interpreted by the participant.
      def transfer_context(scope)
        raise ArgumentError, "there is no control request" unless control_request
        @store.participate(scope) do |records|
          manifest = SavedContextReader.manifest_from_ref(@agent, @current.metadata.fetch("manifest_ref"))
          TransferProjection.new.build(request: control_request, manifest: manifest, persistence: records, source_agent: @agent)
        end
      end

      private

      def validate_binding!
        return unless extension
        binding = @participant&.binding
        unless binding && binding.binding_key == extension.binding_key && binding.binding_version == extension.binding_version
          raise Phronomy::ExecutionRehydrationRequiredError, "Execution #{execution_id} needs participant #{extension.binding_key}@#{extension.binding_version}"
        end
      end

      def attach_state(execution, state)
        execution.with(execution_revision: execution.execution_revision,
          metadata: execution.metadata.merge("execution_extension" => state&.to_h).compact)
      end

      def snapshot(scope)
        agent_state = @store.participate(scope) do |records|
          root = records.agents.load(agent_id)
          execution = records.executions.load(execution_id)
          journal = records.journals.read(agent_id, after: @root.journal_position,
            limit: [root.journal_position - @root.journal_position, 1].max)
          ref = execution.metadata.dig("execution_extension", "state_ref")
          [root.to_h, execution.to_h, journal.map(&:to_h), ref && records.contents.fetch_json(ref), records.cancellations.requested?(agent_id, execution_id)]
        end
        [agent_state, @participant&.change_evidence(self, scope)]
      end
    end
  end
end
