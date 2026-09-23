# frozen_string_literal: true

require "securerandom"

# Raw Backend SPI checks deliberately use opaque records. The domain-facing
# examples separately require AgentBusyError from Persistence repositories.
RSpec.shared_examples "storage execution constraint notifications" do
  [
    [:agents, :executions, :agent_id, :agent_revision, :execution_id],
    [:teams, :team_executions, :team_id, :team_revision, :team_execution_id]
  ].each do |roots, executions, owner_key, root_revision_key, execution_key|
    context "for raw #{executions}" do
      let(:constraint_backend) { persistence.backend }
      let(:constraint_owner_id) { "constraint-owner-#{SecureRandom.uuid}" }
      let(:constraint_execution_id) { "constraint-run-#{SecureRandom.uuid}" }
      let(:constraint_record) do
        Phronomy::Storage::DurableRecord.new(record_type: "opaque.constraint-test",
          format_version: "0.1", payload: {"value" => "unchanged"})
      end
      let(:constraint_arguments) do
        {owner_key => constraint_owner_id, execution_key => constraint_execution_id,
         :execution_revision => 0, :record => constraint_record}
      end
      let(:constraint_repository) { constraint_backend.public_send(executions) }

      before do
        constraint_backend.public_send(roots).create(
          **{owner_key => constraint_owner_id, root_revision_key => 0, :record => constraint_record}
        )
        constraint_repository.create_active(**constraint_arguments)
      end

      it "reports the active-execution subtype for admission and idle checks" do
        expect do
          constraint_repository.create_active(**constraint_arguments.merge(execution_key => SecureRandom.uuid))
        end.to raise_error(Phronomy::Storage::ActiveExecutionConflictError)
        expect do
          constraint_repository.assert_idle!(constraint_owner_id)
        end.to raise_error(Phronomy::Storage::ActiveExecutionConflictError)
        expect(constraint_repository.list_active(constraint_owner_id).length).to eq(1)
        expect(constraint_repository.load(constraint_execution_id).payload).to eq(constraint_record.payload)
      end

      it "keeps duplicate execution identity distinct from active-owner conflict" do
        expect do
          constraint_repository.create_active(**constraint_arguments)
        end.to raise_error(Phronomy::Storage::ConflictError) { |error|
          expect(error).not_to be_a(Phronomy::Storage::ActiveExecutionConflictError)
        }
      end

      it "keeps stale revisions distinct from active-owner conflict" do
        expect do
          constraint_repository.save(constraint_execution_id,
            **{owner_key => constraint_owner_id, :expected_revision => 10,
               :next_revision => 11, :active => true, :record => constraint_record})
        end.to raise_error(Phronomy::Storage::ConflictError) { |error|
          expect(error).not_to be_a(Phronomy::Storage::ActiveExecutionConflictError)
        }
      end

      it "preserves active-owner exclusion when an inactive execution is updated" do
        inactive = Phronomy::Storage::DurableRecord.new(record_type: "opaque.constraint-test",
          format_version: "0.1", payload: {"value" => "inactive"})
        update = {owner_key => constraint_owner_id, :expected_revision => 0,
                  :next_revision => 1, :active => false, :record => inactive}
        constraint_repository.save(constraint_execution_id, **update)
        competing_id = "competing-#{SecureRandom.uuid}"
        constraint_repository.create_active(**constraint_arguments.merge(execution_key => competing_id))

        error_class = (executions == :executions) ?
          Phronomy::Storage::ActiveExecutionConflictError : Phronomy::Storage::ConflictError
        expect do
          constraint_repository.save(constraint_execution_id,
            **update.merge(expected_revision: 1, next_revision: 2, active: true, record: constraint_record))
        end.to raise_error(error_class)
        expect(constraint_repository.list_active(constraint_owner_id).length).to eq(1)
        expect(constraint_repository.load(constraint_execution_id).payload).to eq(inactive.payload)

        # A rejected update must preserve the revision as well as the record.
        expect do
          constraint_repository.save(constraint_execution_id,
            **update.merge(expected_revision: 1, next_revision: 2))
        end.not_to raise_error
      end

      it "allows an active execution to advance without conflicting with itself" do
        expect do
          constraint_repository.save(constraint_execution_id,
            **{owner_key => constraint_owner_id, :expected_revision => 0,
               :next_revision => 1, :active => true, :record => constraint_record})
        end.not_to raise_error
        expect(constraint_repository.list_active(constraint_owner_id).length).to eq(1)
      end

      it "rolls back preceding writes when a raw admission conflict escapes the transaction" do
        content_id = nil
        expect do
          constraint_backend.transaction do |tx|
            content_id = tx.contents.put_text("constraint-rollback-#{SecureRandom.uuid}")
            tx.public_send(executions).create_active(
              **constraint_arguments.merge(execution_key => SecureRandom.uuid)
            )
          end
        end.to raise_error(Phronomy::Storage::ActiveExecutionConflictError)
        expect(constraint_backend.contents.exist?(content_id)).to be(false)
        expect(constraint_repository.list_active(constraint_owner_id).length).to eq(1)
      end
    end
  end
end
