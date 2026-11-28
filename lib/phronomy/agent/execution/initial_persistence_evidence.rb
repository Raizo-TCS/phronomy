# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    # Exact persistence facts for one initial admission, activation or failure.
    # The initial owner retains the proposal; this proof only compares and writes
    # captured records under the original Store and current domain guards.
    # @api private
    class InitialPersistenceEvidence
      ContentWrite = Data.define(:reference, :bytes, :canonicalization_version)
      Result = Data.define(:disposition, :evidence, :original_error, :read_error, :continuation_error)

      # Content construction finishes before the first durable proposal write.
      # The fallback reader is transaction-local and never retained by the proof.
      class Contents < Phronomy::ContentStore::Base
        def initialize(contents)
          @contents, @values, @writes = contents, {}, []
        end

        def put(bytes, canonicalization_version:)
          value = String(bytes).b.dup.freeze
          version = Integer(canonicalization_version)
          reference = content_id_for(value).freeze
          @values[reference] = value
          @writes << ContentWrite.new(reference: reference, bytes: value, canonicalization_version: version)
          reference
        end

        def writes = @writes.dup.freeze
        def fetch(reference) = (@values[reference] || @contents.fetch(reference)).dup
        def exist?(reference) = @values.key?(reference) || @contents.exist?(reference)
      end

      attr_reader :stage, :agent_id, :execution_id, :root, :execution, :next_root,
        :appended_records, :content_writes, :before, :after

      def self.capture(stage:, persistence:, scope:, root:, current_execution:, execution:, next_root:,
        content_writes:, appended_records: [], authority: nil)
        new(stage: stage, persistence: persistence, root: root, current_execution: current_execution,
          execution: execution, next_root: next_root, content_writes: content_writes,
          appended_records: appended_records, authority: authority).send(:capture_in, persistence, scope)
      end

      def initialize(stage:, persistence:, root:, current_execution:, execution:, next_root:,
        content_writes:, appended_records:, authority:)
        @stage, @root, @current_execution = stage, root, current_execution
        @execution, @next_root = execution, next_root
        @identity, @authority = persistence.execution_evidence_identity, authority
        @agent_id, @execution_id = execution.agent_id, execution.execution_id
        @journal_position = root.journal_position
        @appended_records = appended_records.each_with_index.map { |record, index|
          record.with_sequence(@journal_position + index + 1)
        }.freeze
        @content_writes = content_writes.map do |write|
          ContentWrite.new(reference: write.reference.dup.freeze, bytes: write.bytes.b.dup.freeze,
            canonicalization_version: write.canonicalization_version)
        end.freeze
        validate_proposal!
      end
      private_class_method :new

      def apply_in(persistence:, scope:)
        require_persistence!(persistence)
        guard(persistence, scope)
        unless classify(persistence, scope) == :not_committed
          raise Phronomy::Persistence::StateConflictError, "Initial proposal no longer matches its captured pre-state"
        end
        assert_write_authority!(persistence, scope)
        persistence.participate(scope) { |records| write_captured(records) }
        unless classify(persistence, scope) == :committed
          raise Phronomy::Persistence::StateConflictError, "Initial proposal differs from its captured post-state"
        end
        self
      end

      def reconcile(persistence:, original_error: nil)
        require_persistence!(persistence)
        continuation_error = nil
        disposition = persistence.coordinator.atomic do |scope|
          guard(persistence, scope)
          classify(persistence, scope).tap do |current|
            continuation_error = continuation_error_in(persistence, scope) if current == :committed
          end
        end
        result(disposition, original_error: original_error, continuation_error: continuation_error)
      rescue => error
        result(:unknown, original_error: original_error, read_error: error)
      end

      def retry(persistence:, original_error: nil)
        require_persistence!(persistence)
        continuation_error = retry_error = nil
        disposition = persistence.coordinator.atomic do |scope|
          guard(persistence, scope)
          current = classify(persistence, scope)
          if current == :not_committed
            begin
              assert_write_authority!(persistence, scope)
            rescue => error
              retry_error = error
              next :not_committed
            end
            persistence.participate(scope) { |records| write_captured(records) }
            current = classify(persistence, scope)
            unless current == :committed
              raise Phronomy::Persistence::StateConflictError, "Retried initial proposal differs from its captured post-state"
            end
          end
          continuation_error = continuation_error_in(persistence, scope) if current == :committed
          current
        end
        result(disposition, original_error: original_error, read_error: retry_error, continuation_error: continuation_error)
      rescue => error
        reconcile(persistence: persistence, original_error: error)
      end

      private

      def capture_in(persistence, scope)
        guard(persistence, scope)
        observed = snapshot(persistence, scope)
        if stage == :admission && !observed.fetch(:active).empty?
          raise Phronomy::AgentBusyError, "Agent #{agent_id.inspect} already has a durable active execution"
        end
        expected = footprint(root, @current_execution, [], observed.fetch(:cancellation))
        unless observed == expected
          raise Phronomy::Persistence::StateConflictError, "Initial proposal was prepared against another durable state"
        end
        @before = Phronomy::Values::Immutable.copy(observed)
        @after = Phronomy::Values::Immutable.copy(footprint(next_root, execution, appended_records, observed.fetch(:cancellation)))
        freeze
      end

      def validate_proposal!
        unless %i[admission activation failure].include?(stage)
          raise ArgumentError, "Unknown initial persistence stage"
        end
        if execution.metadata["reservation"] && !@authority
          raise ArgumentError, "Reserved initial persistence requires its captured authority"
        end
        current_identity = !@current_execution || (@current_execution.agent_id == agent_id && @current_execution.execution_id == execution_id)
        unless root.agent_id == agent_id && next_root.agent_id == agent_id && current_identity
          raise ArgumentError, "Initial persistence proposal identity mismatch"
        end
        if stage == :admission
          valid = @current_execution.nil? && execution.status == :preparing && execution.execution_revision.zero?
        else
          valid = @current_execution&.active? && execution.execution_revision == @current_execution.execution_revision + 1
          valid &&= (stage == :activation) ? (execution.status == :active && execution.phase == :calling_llm) : %i[failed cancelled blocked].include?(execution.status)
        end
        raise ArgumentError, "Initial persistence stage contradicts its execution transition" unless valid
        root_unchanged = root.to_h == next_root.to_h
        root_revision_valid = root_unchanged || next_root.agent_revision == root.agent_revision + 1
        unless root_revision_valid &&
            next_root.journal_position == @journal_position + appended_records.size &&
            appended_records.all? { |record| record.agent_id == agent_id && record.execution_id == execution_id }
          raise ArgumentError, "Initial persistence proposal has inconsistent root or journal facts"
        end
        content_writes.each do |write|
          unless write.reference == "sha256:#{Digest::SHA256.hexdigest(write.bytes)}" && write.canonicalization_version.is_a?(Integer)
            raise ArgumentError, "Initial persistence proposal contains invalid content facts"
          end
        end
      end

      def guard(persistence, scope)
        unless scope.outermost?
          raise Phronomy::Persistence::TransactionError, "Initial persistence proof requires its own outer transaction"
        end
        @authority&.guard(scope: scope, persistence: persistence)
        persistence.guard_agents(scope, agent_ids: [agent_id])
      end

      def require_persistence!(persistence)
        return if persistence.execution_evidence_identity.equal?(@identity)
        raise Phronomy::Persistence::StateConflictError, "Initial persistence proof belongs to another Store"
      end

      def footprint(observed_root, observed_execution, records, cancellation)
        {root: observed_root.to_h, execution: observed_execution&.to_h,
         journal: records.map(&:to_h), journal_head: observed_root.journal_position,
         cancellation: cancellation,
         active: observed_execution&.active? ? [observed_execution.to_h] : []}
      end

      def snapshot(persistence, scope)
        persistence.participate(scope) do |records|
          observed_root = records.agents.load(agent_id)
          observed_execution = begin
            records.executions.load(execution_id)
          rescue Phronomy::Persistence::NotFoundError
            nil
          end
          head = records.journals.head(agent_id)
          journal = records.journals.read(agent_id, after: @journal_position, limit: [head - @journal_position, 1].max)
          {root: observed_root.to_h, execution: observed_execution&.to_h,
           journal: journal.map(&:to_h), journal_head: head,
           cancellation: records.cancellations.requested?(agent_id, execution_id),
           active: records.executions.list_active(agent_id).sort_by(&:execution_id).map(&:to_h)}
        end
      end

      def classify(persistence, scope)
        current = snapshot(persistence, scope)
        # Cancellation is a separate ledger. A later request cannot erase an
        # already saved initial transition; it separately prevents new dispatch.
        disposition = Phronomy::Persistence::SaveOutcome.compare(
          before: before.except(:cancellation), after: after.except(:cancellation)
        ) { current.except(:cancellation) }.disposition
        if disposition == :committed
          persistence.participate(scope) do |records|
            content_writes.each do |write|
              unless records.contents.fetch(write.reference) == write.bytes
                raise Phronomy::ContentStore::IntegrityError, "Initial persistence content differs from its captured bytes"
              end
            end
          end
        end
        disposition
      end

      def write_captured(records)
        content_writes.each do |write|
          reference = records.contents.put(write.bytes, canonicalization_version: write.canonicalization_version)
          unless reference == write.reference
            raise Phronomy::ContentStore::IntegrityError, "Initial persistence content reference changed during retry"
          end
        end
        records.journals.append(agent_id, expected_position: @journal_position, records: appended_records) unless appended_records.empty?
        if stage == :admission
          records.executions.create_active(execution)
        else
          records.executions.save(execution_id, expected_revision: @current_execution.execution_revision, execution: execution)
        end
        unless next_root.to_h == root.to_h
          records.agents.save(agent_id, expected_revision: root.agent_revision, root: next_root)
        end
      end

      def continuation_error_in(persistence, scope)
        assert_write_authority!(persistence, scope) unless stage == :failure
        nil
      rescue => error
        error
      end

      def assert_write_authority!(persistence, scope)
        if stage == :failure
          @authority&.assert_cleanup!(scope: scope, persistence: persistence)
        else
          cancelled = persistence.participate(scope) { |records| records.cancellations.requested?(agent_id, execution_id) }
          raise Phronomy::CancellationError, "Initial execution was cancelled before continuation" if cancelled
          @authority&.assert_current!(scope: scope, persistence: persistence)
        end
      end

      def result(disposition, original_error:, read_error: nil, continuation_error: nil)
        Result.new(disposition: disposition, evidence: self, original_error: original_error,
          read_error: read_error, continuation_error: continuation_error)
      end
    end
  end
end
