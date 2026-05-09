# frozen_string_literal: true

require "spec_helper"

# Helper for stubbing messages
def make_message(role, content)
  double("Message", role: role.to_sym, content: content, tool_calls: nil)
end

RSpec.describe Phronomy::Memory::Retrieval::Composite do
  let(:user_msgs) { (1..4).map { |i| make_message(:user, "u#{i}") } }
  let(:system_msgs) { [make_message(:system, "sys")] }

  let(:source_a) do
    double("Retrieval").tap do |r|
      allow(r).to receive(:select) { |msgs, **| msgs[0..1] }
    end
  end

  let(:source_b) do
    double("Retrieval").tap do |r|
      allow(r).to receive(:select) { |msgs, **| msgs[1..2] }
    end
  end

  subject(:composite) do
    described_class.new(sources: [
      {retrieval: source_a, weight: 0.5},
      {retrieval: source_b, weight: 0.5}
    ])
  end

  describe "#select" do
    it "merges results from all sources, deduplicating by role+content" do
      result = composite.select(user_msgs)
      # u1, u2 from source_a; u2, u3 from source_b — u2 appears in both
      expect(result.map(&:content)).to eq(["u1", "u2", "u3"])
    end

    it "sorts system messages to the front" do
      all = system_msgs + user_msgs
      src = instance_double(Phronomy::Memory::Retrieval::Recent)
      allow(src).to receive(:select) { all }
      comp = described_class.new(sources: [{retrieval: src}])
      result = comp.select(all)
      expect(result.first.role).to eq(:system)
    end

    it "passes query keyword to each child retrieval" do
      expect(source_a).to receive(:select).with(user_msgs, query: "hi")
      expect(source_b).to receive(:select).with(user_msgs, query: "hi")
      composite.select(user_msgs, query: "hi")
    end
  end

  describe "#index delegation" do
    it "forwards index to child retrievals that respond to it" do
      allow(source_a).to receive(:respond_to?).with(:index).and_return(true)
      allow(source_b).to receive(:respond_to?).with(:index).and_return(false)
      expect(source_a).to receive(:index).with(thread_id: "t1", messages: user_msgs)
      expect(source_b).not_to receive(:index)
      composite.index(thread_id: "t1", messages: user_msgs)
    end
  end

  describe "#clear_index delegation" do
    it "forwards clear_index to child retrievals that respond to it" do
      allow(source_a).to receive(:respond_to?).with(:clear_index).and_return(true)
      allow(source_b).to receive(:respond_to?).with(:clear_index).and_return(true)
      expect(source_a).to receive(:clear_index).with(thread_id: "t1")
      expect(source_b).to receive(:clear_index).with(thread_id: "t1")
      composite.clear_index(thread_id: "t1")
    end
  end
end
