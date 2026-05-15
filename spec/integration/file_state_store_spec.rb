# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require "tmpdir"
require "fileutils"

# Group 29: File State Store (Phronomy::StateStore::File)
#
# Pairwise factors:
#   file_store_dir_type            x  file_store_thread_id_type
#   file_store_operation           x  file_store_workflow_integration
#
# Generated cases : 6
# Infeasible cases: 0 (none — all factor combinations are structurally valid)
# LLM required    : No (pure-Ruby; no LM Studio connection needed)

RSpec.describe "Group 29: File State Store", :integration do
  class FileStoreTestContext
    include Phronomy::WorkflowContext

    field :value, type: :replace, default: ""
    field :count, type: :replace, default: 0
  end

  def make_state(value:, thread_id:, phase: :__end__)
    s = FileStoreTestContext.new(value: value)
    s.set_graph_metadata(thread_id: thread_id, phase: phase)
    s
  end

  # ---------------------------------------------------------------------------
  # TC-001: default dir + simple thread_id + save_load + standalone
  # ---------------------------------------------------------------------------
  describe "TC-001: default dir / simple thread_id / save_load / standalone" do
    it "round-trips value, thread_id, and phase to the default temp directory" do
      store = Phronomy::StateStore::File.new
      thread_id = IntegrationFactors.file_store_thread_id("simple", base: "tc001")
      state = make_state(value: "hello", thread_id: thread_id, phase: :awaiting_resume)
      begin
        store.save(state)
        loaded = store.load(thread_id)
        expect(loaded).not_to be_nil
        expect(loaded.value).to eq("hello")
        expect(loaded.thread_id).to eq(thread_id)
        expect(loaded.phase).to eq(:awaiting_resume)
        expect(loaded.halted?).to be(true)
      ensure
        store.clear(thread_id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: default dir + special_chars thread_id + clear + with_workflow
  # ---------------------------------------------------------------------------
  describe "TC-002: default dir / special_chars thread_id / clear / with_workflow" do
    it "workflow halts, then clear removes the state file so load returns nil" do
      store = Phronomy::StateStore::File.new
      thread_id = IntegrationFactors.file_store_thread_id("special_chars", base: "tc002")
      workflow = IntegrationFactors.file_store_workflow(FileStoreTestContext, store: store)
      begin
        halted = workflow.invoke({value: "start"}, config: {thread_id: thread_id})
        expect(halted.halted?).to be(true)
        expect(store.load(thread_id)).not_to be_nil

        store.clear(thread_id)
        expect(store.load(thread_id)).to be_nil
      ensure
        store.clear(thread_id)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: default dir + simple thread_id + clear_all + with_workflow
  # ---------------------------------------------------------------------------
  describe "TC-003: default dir / simple thread_id / clear_all / with_workflow" do
    it "workflow halts for two threads, clear_all removes both state files" do
      store = Phronomy::StateStore::File.new
      tid1 = IntegrationFactors.file_store_thread_id("simple", base: "tc003a")
      tid2 = IntegrationFactors.file_store_thread_id("simple", base: "tc003b")
      workflow = IntegrationFactors.file_store_workflow(FileStoreTestContext, store: store)
      begin
        workflow.invoke({value: "x"}, config: {thread_id: tid1})
        workflow.invoke({value: "y"}, config: {thread_id: tid2})
        expect(store.load(tid1)).not_to be_nil
        expect(store.load(tid2)).not_to be_nil

        store.clear_all
        expect(store.load(tid1)).to be_nil
        expect(store.load(tid2)).to be_nil
      ensure
        store.clear(tid1)
        store.clear(tid2)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: custom dir + simple thread_id + clear + standalone
  # ---------------------------------------------------------------------------
  describe "TC-004: custom dir / simple thread_id / clear / standalone" do
    it "saves to a custom directory, then clear leaves load returning nil" do
      custom_dir = Dir.mktmpdir("phronomy_it_29_tc004_")
      store = IntegrationFactors.file_store("custom", custom_dir: custom_dir)
      thread_id = IntegrationFactors.file_store_thread_id("simple", base: "tc004")
      state = make_state(value: "custom_test", thread_id: thread_id)
      begin
        store.save(state)
        expect(store.load(thread_id)).not_to be_nil
        expect(store.directory).to eq(File.expand_path(custom_dir))

        store.clear(thread_id)
        expect(store.load(thread_id)).to be_nil
      ensure
        FileUtils.rm_rf(custom_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: custom dir + special_chars thread_id + save_load + with_workflow
  # ---------------------------------------------------------------------------
  describe "TC-005: custom dir / special_chars thread_id / save_load / with_workflow" do
    it "workflow halts and resumes with special-char thread_id in a custom directory" do
      custom_dir = Dir.mktmpdir("phronomy_it_29_tc005_")
      store = IntegrationFactors.file_store("custom", custom_dir: custom_dir)
      thread_id = IntegrationFactors.file_store_thread_id("special_chars", base: "tc005")
      workflow = IntegrationFactors.file_store_workflow(FileStoreTestContext, store: store)
      begin
        halted = workflow.invoke({value: "start"}, config: {thread_id: thread_id})
        expect(halted.halted?).to be(true)
        expect(halted.value).to eq("start:a")

        loaded = store.load(thread_id)
        expect(loaded).not_to be_nil
        expect(loaded.value).to eq("start:a")

        final = workflow.send_event(state: halted, event: :resume)
        expect(final.halted?).to be(false)
        expect(final.value).to eq("start:a:b")
      ensure
        FileUtils.rm_rf(custom_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: custom dir + special_chars thread_id + clear_all + standalone
  # ---------------------------------------------------------------------------
  describe "TC-006: custom dir / special_chars thread_id / clear_all / standalone" do
    it "saves multiple states with special-char thread_ids, clear_all removes all" do
      custom_dir = Dir.mktmpdir("phronomy_it_29_tc006_")
      store = IntegrationFactors.file_store("custom", custom_dir: custom_dir)
      thread_ids = [
        IntegrationFactors.file_store_thread_id("special_chars", base: "tc006a"),
        IntegrationFactors.file_store_thread_id("special_chars", base: "tc006b")
      ]
      begin
        thread_ids.each_with_index do |tid, i|
          store.save(make_state(value: "v#{i}", thread_id: tid))
        end
        thread_ids.each { |tid| expect(store.load(tid)).not_to be_nil }

        store.clear_all
        thread_ids.each { |tid| expect(store.load(tid)).to be_nil }
      ensure
        FileUtils.rm_rf(custom_dir)
      end
    end
  end
end
