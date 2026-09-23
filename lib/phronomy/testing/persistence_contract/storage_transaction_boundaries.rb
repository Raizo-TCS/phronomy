# frozen_string_literal: true

require "securerandom"

RSpec.shared_examples "storage transaction boundaries" do
  [:backend, :persistence].each do |entry_point|
    context "through #{entry_point} transactions" do
      def transaction_contents(view)
        view.is_a?(Phronomy::Storage::View) ? Phronomy::ContentStore::StoredContents.new(view) : view.contents
      end

      let(:transaction_service) { (entry_point == :backend) ? persistence.backend : persistence }

      it "rolls back a failed inner scope and re-raises the same error before the outer scope continues" do
        outer_id = inner_id = later_id = nil
        workflow_id = "nested-#{SecureRandom.uuid}"
        failure = RuntimeError.new("inner failure")

        result = transaction_service.transaction do |outer|
          outer_id = transaction_contents(outer).put_text("outer-#{workflow_id}")
          expect do
            transaction_service.transaction do |inner|
              inner_id = transaction_contents(inner).put_text("inner-#{workflow_id}")
              if entry_point == :backend
                inner.records(Phronomy::WorkflowStorageSchema::STATES).insert(key: workflow_id,
                  revision: 1, attributes: {}, record: Phronomy::Storage::DurableRecord.new(
                    record_type: "opaque.transaction", format_version: "0.1", payload: {"value" => "inner"}
                  ))
              else
                inner.workflow_states.save(workflow_id,
                  expected_revision: nil, snapshot: {fields: {value: "inner"}, phase: "pause"})
              end
              raise failure
            end
          end.to raise_error { |error| expect(error).to equal(failure) }
          expect(transaction_contents(outer).exist?(outer_id)).to be(true)
          expect(transaction_contents(outer).exist?(inner_id)).to be(false)
          expect(persistence.backend.view.records(Phronomy::WorkflowStorageSchema::STATES).read(workflow_id)).to be_nil
          later_id = transaction_contents(outer).put_text("later-#{workflow_id}")
          :outer_result
        end

        expect(result).to eq(:outer_result)
        expect(persistence.contents.exist?(outer_id)).to be(true)
        expect(persistence.contents.exist?(later_id)).to be(true)
        expect(persistence.contents.exist?(inner_id)).to be(false)
        expect(persistence.backend.view.records(Phronomy::WorkflowStorageSchema::STATES).read(workflow_id)).to be_nil
      end

      it "commits both scopes on normal completion and returns their block values" do
        outer_id = inner_id = nil
        result = transaction_service.transaction do |outer|
          outer_id = transaction_contents(outer).put_text("outer-#{SecureRandom.uuid}")
          inner_result = transaction_service.transaction do |inner|
            inner_id = transaction_contents(inner).put_text("inner-#{SecureRandom.uuid}")
            :inner_result
          end
          expect(inner_result).to eq(:inner_result)
          :outer_result
        end
        expect(result).to eq(:outer_result)
        expect(persistence.contents.exist?(outer_id)).to be(true)
        expect(persistence.contents.exist?(inner_id)).to be(true)
      end

      it "rolls back successful inner writes when the outer scope fails" do
        outer_id = inner_id = nil
        expect do
          transaction_service.transaction do |outer|
            outer_id = transaction_contents(outer).put_text("outer-#{SecureRandom.uuid}")
            result = transaction_service.transaction do |inner|
              inner_id = transaction_contents(inner).put_text("inner-#{SecureRandom.uuid}")
              :inner_result
            end
            expect(result).to eq(:inner_result)
            expect(transaction_contents(outer).exist?(inner_id)).to be(true)
            raise "outer failure"
          end
        end.to raise_error("outer failure")
        expect(persistence.contents.exist?(outer_id)).to be(false)
        expect(persistence.contents.exist?(inner_id)).to be(false)
      end

      it "rolls back both scopes when an inner error escapes the outer scope" do
        outer_id = inner_id = nil
        expect do
          transaction_service.transaction do |outer|
            outer_id = transaction_contents(outer).put_text("outer-#{SecureRandom.uuid}")
            transaction_service.transaction do |inner|
              inner_id = transaction_contents(inner).put_text("inner-#{SecureRandom.uuid}")
              raise "uncaught inner failure"
            end
          end
        end.to raise_error("uncaught inner failure")
        expect(persistence.contents.exist?(outer_id)).to be(false)
        expect(persistence.contents.exist?(inner_id)).to be(false)
      end
    end
  end

  it "validates every stream entry before writing any part of a batch" do
    backend = persistence.backend
    schema = Phronomy::Agent::Persistence::StorageSchema
    owner_id = "batch-#{SecureRandom.uuid}"
    record = Phronomy::Storage::DurableRecord.new(record_type: "opaque.transaction", format_version: "0.1", payload: {})
    backend.view.records(schema::ROOTS).insert(key: owner_id, revision: 0, attributes: {}, record: record)
    valid = Phronomy::Storage::Entry::Append.new(id: "first", record: record)
    content_id = nil
    backend.transaction do |view|
      content_id = persistence.contents.put_text("retained-#{owner_id}")
      stream = view.streams(schema::JOURNAL)
      expect { stream.append(stream: owner_id, expected_head: 0, entries: [valid, Object.new]) }
        .to raise_error(Phronomy::Storage::SerializationError)
      expect(stream.head(stream: owner_id)).to eq(0)
      expect(stream.read(stream: owner_id)).to be_empty
    end
    expect(persistence.contents.exist?(content_id)).to be(true)
    entries = backend.view.streams(schema::JOURNAL).append(stream: owner_id, expected_head: 0,
      entries: [valid, Phronomy::Storage::Entry::Append.new(id: "second", record: record)])
    expect(entries.map(&:position)).to eq([1, 2])
    expect(entries.map { |entry| entry.record.payload }).to eq([{}, {}])
  end
end
