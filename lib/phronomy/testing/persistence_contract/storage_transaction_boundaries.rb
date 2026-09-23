# frozen_string_literal: true

require "securerandom"

RSpec.shared_examples "storage transaction boundaries" do
  [:backend, :persistence].each do |entry_point|
    context "through #{entry_point} transactions" do
      let(:transaction_service) { (entry_point == :backend) ? persistence.backend : persistence }

      it "rolls back a failed inner scope and re-raises the same error before the outer scope continues" do
        outer_id = inner_id = later_id = nil
        workflow_id = "nested-#{SecureRandom.uuid}"
        failure = RuntimeError.new("inner failure")

        result = transaction_service.transaction do |outer|
          outer_id = outer.contents.put_text("outer-#{workflow_id}")
          expect do
            transaction_service.transaction do |inner|
              inner_id = inner.contents.put_text("inner-#{workflow_id}")
              if entry_point == :backend
                inner.workflow_states.save(workflow_id,
                  expected_revision: nil, next_revision: 1,
                  record: Phronomy::Storage::DurableRecord.new(record_type: "opaque.transaction",
                    format_version: "0.1", payload: {"value" => "inner"}))
              else
                inner.workflow_states.save(workflow_id,
                  expected_revision: nil, snapshot: {fields: {value: "inner"}, phase: "pause"})
              end
              raise failure
            end
          end.to raise_error { |error| expect(error).to equal(failure) }
          expect(outer.contents.exist?(outer_id)).to be(true)
          expect(outer.contents.exist?(inner_id)).to be(false)
          expect(persistence.backend.workflow_states.load(workflow_id)).to be_nil
          later_id = outer.contents.put_text("later-#{workflow_id}")
          :outer_result
        end

        expect(result).to eq(:outer_result)
        expect(persistence.contents.exist?(outer_id)).to be(true)
        expect(persistence.contents.exist?(later_id)).to be(true)
        expect(persistence.contents.exist?(inner_id)).to be(false)
        expect(persistence.backend.workflow_states.load(workflow_id)).to be_nil
      end

      it "commits both scopes on normal completion and returns their block values" do
        outer_id = inner_id = nil
        result = transaction_service.transaction do |outer|
          outer_id = outer.contents.put_text("outer-#{SecureRandom.uuid}")
          inner_result = transaction_service.transaction do |inner|
            inner_id = inner.contents.put_text("inner-#{SecureRandom.uuid}")
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
            outer_id = outer.contents.put_text("outer-#{SecureRandom.uuid}")
            result = transaction_service.transaction do |inner|
              inner_id = inner.contents.put_text("inner-#{SecureRandom.uuid}")
              :inner_result
            end
            expect(result).to eq(:inner_result)
            expect(outer.contents.exist?(inner_id)).to be(true)
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
            outer_id = outer.contents.put_text("outer-#{SecureRandom.uuid}")
            transaction_service.transaction do |inner|
              inner_id = inner.contents.put_text("inner-#{SecureRandom.uuid}")
              raise "uncaught inner failure"
            end
          end
        end.to raise_error("uncaught inner failure")
        expect(persistence.contents.exist?(outer_id)).to be(false)
        expect(persistence.contents.exist?(inner_id)).to be(false)
      end
    end
  end

  it "validates every raw Journal record before writing any part of a batch" do
    backend = persistence.backend
    owner_id = "journal-batch-#{SecureRandom.uuid}"
    record = Phronomy::Storage::DurableRecord.new(record_type: "opaque.transaction",
      format_version: "0.1", payload: {"value" => "valid"})
    backend.agents.create(agent_id: owner_id, agent_revision: 0, record: record)
    content_id = nil

    backend.transaction do |tx|
      content_id = tx.contents.put_text("retained-#{owner_id}")
      expect do
        tx.journals.append(owner_id, expected_position: 0,
          records: [record, Object.new], record_ids: ["first", "second"])
      end.to raise_error(Phronomy::Storage::SerializationError)
      expect(tx.journals.head(owner_id)).to eq(0)
      expect(tx.journals.read(owner_id)).to be_empty
    end

    expect(backend.contents.exist?(content_id)).to be(true)
    expect(backend.journals.head(owner_id)).to eq(0)
    expect(backend.journals.read(owner_id)).to be_empty
    # Reusing both identities also detects an orphan row or consumed sequence.
    appended = backend.journals.append(owner_id, expected_position: 0,
      records: [record, record], record_ids: ["first", "second"])
    expect(appended.map(&:payload)).to eq([record.payload, record.payload])
    expect(backend.journals.head(owner_id)).to eq(2)
    expect(backend.journals.read(owner_id).length).to eq(2)
  end
end
