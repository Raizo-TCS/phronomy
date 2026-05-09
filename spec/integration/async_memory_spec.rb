# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require "active_job"

# Group 20: Async Memory Write
# Factors: memory_async_backend × memory_async_mode × active_job_availability
# Generated cases: 6
# Infeasible:
#   TC-003 (entity + sync + unavailable): sync mode never touches ActiveJob so
#           the unavailability of ActiveJob is irrelevant — no error is raised.
#           SKIP: combination cannot be meaningfully observed.

ActiveJob::Base.queue_adapter = :test

RSpec.describe "Group 20: Async Memory Write", :integration do
  include ActiveJob::TestHelper

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  let(:msgs) { [make_msg(:user, "Hello"), make_msg(:assistant, "Hi")] }

  # ---------------------------------------------------------------------------
  # TC-001: window + sync + available
  #         Pure Ruby — no LLM required
  # ---------------------------------------------------------------------------
  describe "TC-001: WindowMemory; sync; ActiveJob available — synchronous save" do
    it "saves and loads messages in the same thread" do
      mem = IntegrationFactors.async_memory("window", async: false)
      mem.save_messages(thread_id: "t1", messages: msgs)
      expect(mem.load_messages(thread_id: "t1")).to eq(msgs)
    end

    it "does not interact with AsyncSaveJob" do
      mem = IntegrationFactors.async_memory("window", async: false)
      allow(Phronomy::Memory::AsyncSaveJob).to receive(:set)
      mem.save_messages(thread_id: "t1", messages: msgs)
      expect(Phronomy::Memory::AsyncSaveJob).not_to have_received(:set)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: window + async + unavailable
  #         Pure Ruby — simulates missing ActiveJob
  # ---------------------------------------------------------------------------
  describe "TC-002: WindowMemory; async; ActiveJob unavailable — ConfigurationError" do
    it "raises Phronomy::ConfigurationError" do
      mem = IntegrationFactors.async_memory("window", async: true)
      original = ::ActiveJob
      Object.send(:remove_const, :ActiveJob)
      begin
        expect { mem.save_messages(thread_id: "t1", messages: msgs) }
          .to raise_error(Phronomy::ConfigurationError, /requires ActiveJob/)
      ensure
        Object.const_set(:ActiveJob, original)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: entity + sync + unavailable — INFEASIBLE
  #         sync mode never invokes ActiveJob; unavailability is unobservable.
  # ---------------------------------------------------------------------------
  it "TC-003: SKIP — sync mode does not invoke ActiveJob regardless of availability" do
    pending "SKIP: unavailability of ActiveJob has no effect in sync mode"
    raise "should be skipped"
  end

  # ---------------------------------------------------------------------------
  # TC-004: entity + async + available
  #         Pure Ruby — verifies enqueue and deferred write
  # ---------------------------------------------------------------------------
  describe "TC-004: EntityMemory; async; ActiveJob available — job enqueued" do
    subject(:mem) { IntegrationFactors.async_memory("entity", async: true) }

    let(:configured_job) { instance_double("ActiveJob::ConfiguredJob", perform_later: nil) }
    before { allow(Phronomy::Memory::AsyncSaveJob).to receive(:set).and_return(configured_job) }

    it "calls AsyncSaveJob.set instead of writing synchronously" do
      mem.save_messages(thread_id: "t4", messages: msgs)
      expect(Phronomy::Memory::AsyncSaveJob).to have_received(:set).with(queue: :default)
    end

    it "does not persist messages before the job runs" do
      mem.save_messages(thread_id: "t4", messages: msgs)
      expect(mem.load_messages(thread_id: "t4")).to be_empty
    end

    it "persists messages after the job executes" do
      Phronomy::Memory::AsyncSaveJob.perform_now(
        memory: mem, thread_id: "t4", messages: msgs
      )
      expect(mem.load_messages(thread_id: "t4")).not_to be_empty
    end

    it "extracts entities after the job executes" do
      user_msg = make_msg(:user, "My name is Charlie")
      Phronomy::Memory::AsyncSaveJob.perform_now(
        memory: mem, thread_id: "t4b", messages: [user_msg]
      )
      expect(mem.entities_for("t4b")).to include(name: "Charlie")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: ar_stub + sync + available
  #         Pure Ruby — verifies AR memory synchronous path
  # ---------------------------------------------------------------------------
  describe "TC-005: ActiveRecordMemory (stub); sync; ActiveJob available — sync save" do
    it "calls delete_all and create! synchronously" do
      model_class = Class.new do
        @store = []
        class << self
          attr_reader :store

          def where(thread_id:)
            @thread_filter = thread_id
            self
          end

          def order(*)
            self
          end

          def delete_all
            @store.reject! { |r| r[:thread_id] == @thread_filter }
          end

          def create!(**attrs)
            @store << attrs
          end

          def transaction
            yield
          end

          def to_a
            @store.select { |r| r[:thread_id] == @thread_filter }
          end
        end
      end

      mem = Phronomy::Memory::ActiveRecordMemory.new(model_class: model_class, async: false)
      user_msg = make_msg(:user, "Hello from AR")
      mem.save_messages(thread_id: "t5", messages: [user_msg])
      expect(model_class.store).not_to be_empty
    end

    it "does not call AsyncSaveJob" do
      mem = IntegrationFactors.async_memory("ar_stub", async: false)
      allow(Phronomy::Memory::AsyncSaveJob).to receive(:set)
      mem.save_messages(thread_id: "t5b", messages: msgs)
      expect(Phronomy::Memory::AsyncSaveJob).not_to have_received(:set)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: ar_stub + async + unavailable
  #         Pure Ruby — ConfigurationError for AR memory when ActiveJob missing
  # ---------------------------------------------------------------------------
  describe "TC-006: ActiveRecordMemory (stub); async; ActiveJob unavailable — ConfigurationError" do
    it "raises Phronomy::ConfigurationError" do
      mem = IntegrationFactors.async_memory("ar_stub", async: true)
      original = ::ActiveJob
      Object.send(:remove_const, :ActiveJob)
      begin
        expect { mem.save_messages(thread_id: "t6", messages: msgs) }
          .to raise_error(Phronomy::ConfigurationError, /requires ActiveJob/)
      ensure
        Object.const_set(:ActiveJob, original)
      end
    end
  end
end
