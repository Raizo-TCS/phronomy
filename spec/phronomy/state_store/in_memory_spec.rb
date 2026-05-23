# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::StateStore::InMemory do
  let(:store) { described_class.new }

  # Contract tests: verify InMemory satisfies the state store interface (Issue #250).
  it_behaves_like "a state store" do
    let(:store) { described_class.new }
  end

  describe "thread safety" do
    it "handles concurrent saves and loads without data corruption" do
      threads = 8.times.map do |i|
        Thread.new do
          100.times { store.save("t#{i}", {fields: {value: i}, phase: "__end__"}) }
        end
      end
      threads.each(&:join)

      8.times do |i|
        result = store.load("t#{i}")
        expect(result).to eq({fields: {value: i}, phase: "__end__"}) if result
      end
    end

    it "handles concurrent deletes without raising" do
      20.times { |i| store.save("t#{i}", {fields: {}, phase: "__end__"}) }
      threads = 20.times.map do |i|
        Thread.new { store.delete("t#{i}") }
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  describe "#save returns nil (no meaningful return value)" do
    it "returns nil" do
      expect(store.save("t1", {fields: {}, phase: "__end__"})).to be_nil
    end
  end

  describe "#delete returns nil (no meaningful return value)" do
    it "returns nil on successful delete" do
      store.save("t1", {fields: {}, phase: "__end__"})
      expect(store.delete("t1")).to be_nil
    end

    it "returns nil when thread_id is absent" do
      expect(store.delete("missing")).to be_nil
    end
  end
end
