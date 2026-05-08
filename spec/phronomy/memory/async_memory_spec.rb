# frozen_string_literal: true

require "spec_helper"
require "active_job"

# Use the test adapter so ActiveJob::TestHelper helpers are available.
# Note: the :test adapter serializes job arguments, which means plain Ruby
# objects like WindowMemory cannot be passed via perform_later.  The unit
# tests therefore mock AsyncSaveJob.set/perform_later to verify enqueue
# behaviour without triggering serialization, and call perform_now directly
# to test the actual write path.
ActiveJob::Base.queue_adapter = :test

RSpec.describe "Phronomy::Memory async write support" do
  include ActiveJob::TestHelper

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  let(:msgs) do
    [
      make_msg(:user, "Hello"),
      make_msg(:assistant, "Hi")
    ]
  end

  # ---------------------------------------------------------------------------
  # AsyncCapable module — MRO
  # ---------------------------------------------------------------------------
  describe Phronomy::Memory::AsyncCapable do
    it "is prepended into WindowMemory before the class itself" do
      idx_capable = Phronomy::Memory::WindowMemory.ancestors.index(described_class)
      idx_class = Phronomy::Memory::WindowMemory.ancestors.index(Phronomy::Memory::WindowMemory)
      expect(idx_capable).to be < idx_class
    end

    it "is prepended into EntityMemory" do
      expect(Phronomy::Memory::EntityMemory.ancestors).to include(described_class)
      idx = Phronomy::Memory::EntityMemory.ancestors.index(described_class)
      expect(idx).to be < Phronomy::Memory::EntityMemory.ancestors.index(Phronomy::Memory::EntityMemory)
    end
  end

  # ---------------------------------------------------------------------------
  # Synchronous mode (default)
  # ---------------------------------------------------------------------------
  describe "synchronous mode (async: false)" do
    subject(:memory) { Phronomy::Memory::WindowMemory.new(k: 5) }

    it "defaults to async: false" do
      expect(memory.instance_variable_get(:@_async)).to be false
    end

    it "saves and loads messages synchronously" do
      memory.save_messages(thread_id: "t1", messages: msgs)
      expect(memory.load_messages(thread_id: "t1")).to eq(msgs)
    end

    it "does not invoke AsyncSaveJob" do
      allow(Phronomy::Memory::AsyncSaveJob).to receive(:set)
      memory.save_messages(thread_id: "t1", messages: msgs)
      expect(Phronomy::Memory::AsyncSaveJob).not_to have_received(:set)
    end
  end

  # ---------------------------------------------------------------------------
  # Async mode — enqueue verification (mocked perform_later)
  # ---------------------------------------------------------------------------
  describe "async mode (async: true)" do
    subject(:memory) { Phronomy::Memory::WindowMemory.new(k: 5, async: true) }

    # Stub perform_later to avoid ActiveJob's serialization of in-memory objects.
    let(:configured_job) { instance_double("ActiveJob::ConfiguredJob", perform_later: nil) }
    before { allow(Phronomy::Memory::AsyncSaveJob).to receive(:set).and_return(configured_job) }

    it "accepts async: true in the constructor" do
      expect(memory.instance_variable_get(:@_async)).to be true
    end

    it "calls AsyncSaveJob.set with the :default queue" do
      memory.save_messages(thread_id: "t1", messages: msgs)
      expect(Phronomy::Memory::AsyncSaveJob).to have_received(:set).with(queue: :default)
    end

    it "calls perform_later with correct keyword arguments" do
      memory.save_messages(thread_id: "t1", messages: msgs)
      expect(configured_job).to have_received(:perform_later)
        .with(memory: memory, thread_id: "t1", messages: msgs)
    end

    it "uses a custom queue when specified" do
      mem = Phronomy::Memory::WindowMemory.new(k: 5, async: true, queue: :low)
      mem.save_messages(thread_id: "t1", messages: msgs)
      expect(Phronomy::Memory::AsyncSaveJob).to have_received(:set).with(queue: :low)
    end

    it "does NOT write messages immediately" do
      memory.save_messages(thread_id: "t1", messages: msgs)
      expect(memory.load_messages(thread_id: "t1")).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Async write path — end-to-end via perform_now
  # ---------------------------------------------------------------------------
  describe "async write end-to-end (perform_now)" do
    it "WindowMemory: actual write completes after job executes" do
      mem = Phronomy::Memory::WindowMemory.new(k: 5, async: true)
      Phronomy::Memory::AsyncSaveJob.perform_now(
        memory: mem, thread_id: "t1", messages: msgs
      )
      expect(mem.load_messages(thread_id: "t1")).to eq(msgs)
    end

    it "EntityMemory: entity extraction runs after job executes" do
      mem = Phronomy::Memory::EntityMemory.new(k: 10, async: true)
      user_msg = make_msg(:user, "My name is Alice")
      Phronomy::Memory::AsyncSaveJob.perform_now(
        memory: mem, thread_id: "t2", messages: [user_msg]
      )
      expect(mem.entities_for("t2")).to include(name: "Alice")
    end
  end

  # ---------------------------------------------------------------------------
  # Queue option
  # ---------------------------------------------------------------------------
  describe "queue option" do
    it "uses :default when no queue is specified" do
      mem = Phronomy::Memory::EntityMemory.new(async: true)
      expect(mem.instance_variable_get(:@_async_queue)).to eq(:default)
    end

    it "stores the custom queue name" do
      mem = Phronomy::Memory::EntityMemory.new(async: true, queue: :background)
      expect(mem.instance_variable_get(:@_async_queue)).to eq(:background)
    end
  end

  # ---------------------------------------------------------------------------
  # ConfigurationError when ActiveJob is unavailable
  # ---------------------------------------------------------------------------
  describe "ConfigurationError when ActiveJob is not available" do
    it "raises ConfigurationError if ActiveJob constant is removed" do
      mem = Phronomy::Memory::WindowMemory.new(k: 5, async: true)
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
  # AsyncSaveJob unit
  # ---------------------------------------------------------------------------
  describe Phronomy::Memory::AsyncSaveJob do
    it "disables async flag, calls save_messages synchronously, then restores flag" do
      mem = instance_double(Phronomy::Memory::WindowMemory)
      allow(mem).to receive(:instance_variable_set)
      allow(mem).to receive(:save_messages)

      described_class.perform_now(memory: mem, thread_id: "t1", messages: msgs)

      expect(mem).to have_received(:instance_variable_set).with(:@_async, false).ordered
      expect(mem).to have_received(:save_messages)
        .with(thread_id: "t1", messages: msgs).ordered
      expect(mem).to have_received(:instance_variable_set).with(:@_async, true).ordered
    end
  end

  # ---------------------------------------------------------------------------
  # Global configuration
  # ---------------------------------------------------------------------------
  describe "Phronomy.configuration" do
    after { Phronomy.reset_configuration! }

    it "defaults memory_async to false" do
      expect(Phronomy.configuration.memory_async).to be false
    end

    it "defaults memory_job_queue to :default" do
      expect(Phronomy.configuration.memory_job_queue).to eq(:default)
    end

    it "accepts memory_async = true" do
      Phronomy.configure { |c| c.memory_async = true }
      expect(Phronomy.configuration.memory_async).to be true
    end

    it "accepts a custom memory_job_queue" do
      Phronomy.configure { |c| c.memory_job_queue = :background }
      expect(Phronomy.configuration.memory_job_queue).to eq(:background)
    end
  end
end
