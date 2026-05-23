# frozen_string_literal: true

# Contract tests for Phronomy::StateStore::Base implementations (Issue #250).
#
# Usage:
#   it_behaves_like "a state store" do
#     let(:store) { described_class.new }
#   end
RSpec.shared_examples "a state store" do
  # Callers must supply a `store` let block pointing to a fresh instance.

  describe "interface" do
    it "responds to #load" do
      expect(store).to respond_to(:load)
    end

    it "responds to #save" do
      expect(store).to respond_to(:save)
    end

    it "responds to #delete" do
      expect(store).to respond_to(:delete)
    end
  end

  describe "#load" do
    it "returns nil for an unknown thread_id" do
      expect(store.load("nonexistent-thread")).to be_nil
    end
  end

  describe "#save and #load" do
    it "persists and retrieves a snapshot" do
      snapshot = {fields: {count: 42, name: "alice"}, phase: "__end__"}
      store.save("t1", snapshot)
      expect(store.load("t1")).to eq(snapshot)
    end

    it "overwriting save replaces the previous snapshot" do
      store.save("t1", {fields: {value: 1}, phase: "__end__"})
      store.save("t1", {fields: {value: 2}, phase: "__end__"})
      expect(store.load("t1")).to eq({fields: {value: 2}, phase: "__end__"})
    end

    it "isolates data across different thread_ids" do
      store.save("t1", {fields: {user: "alice"}, phase: "__end__"})
      store.save("t2", {fields: {user: "bob"}, phase: "__end__"})
      expect(store.load("t1")).to eq({fields: {user: "alice"}, phase: "__end__"})
      expect(store.load("t2")).to eq({fields: {user: "bob"}, phase: "__end__"})
    end

    it "load returns a defensive copy so mutations do not affect stored data" do
      store.save("t1", {fields: {tags: ["a"]}, phase: "__end__"})
      fetched = store.load("t1")
      fetched[:fields][:tags] << "b" if fetched[:fields][:tags].is_a?(Array)
      reloaded = store.load("t1")
      expect(reloaded[:fields][:tags]).to eq(["a"])
    end
  end

  describe "#delete" do
    it "removes the snapshot for the given thread_id" do
      store.save("t1", {fields: {x: 1}, phase: "__end__"})
      store.delete("t1")
      expect(store.load("t1")).to be_nil
    end

    it "does not raise when the thread_id is absent" do
      expect { store.delete("nonexistent-thread") }.not_to raise_error
    end

    it "deleting one thread_id does not affect another" do
      store.save("t1", {fields: {x: 1}, phase: "__end__"})
      store.save("t2", {fields: {x: 2}, phase: "__end__"})
      store.delete("t1")
      expect(store.load("t2")).to eq({fields: {x: 2}, phase: "__end__"})
    end
  end
end
