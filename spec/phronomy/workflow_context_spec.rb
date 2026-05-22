# frozen_string_literal: true

require "spec_helper"

# --- State class for testing ---
class TestState
  include Phronomy::WorkflowContext

  field :value, type: :replace, default: 0
  field :messages, type: :append, default: -> { [] }
  field :metadata, type: :merge, default: -> { {} }
  field :step, type: :replace, default: nil
end

RSpec.describe Phronomy::WorkflowContext do
  describe "field DSL" do
    it "defines fields as accessors" do
      s = TestState.new(value: 42)
      expect(s.value).to eq(42)
    end

    it "applies default values (scalar)" do
      s = TestState.new
      expect(s.value).to eq(0)
    end

    it "applies default values (Proc)" do
      s = TestState.new
      expect(s.messages).to eq([])
    end

    it "Proc defaults return a new object each time" do
      s1 = TestState.new
      s2 = TestState.new
      expect(s1.messages).not_to be(s2.messages)
    end
  end

  describe "#merge" do
    let(:state) { TestState.new(value: 1, messages: ["a"], metadata: {x: 1}) }

    context "type: :replace" do
      it "overwrites with the new value" do
        new_state = state.merge(value: 99)
        expect(new_state.value).to eq(99)
      end

      it "does not mutate the original state (immutable)" do
        state.merge(value: 99)
        expect(state.value).to eq(1)
      end
    end

    context "type: :append" do
      it "appends to the end of the array" do
        new_state = state.merge(messages: ["b"])
        expect(new_state.messages).to eq(["a", "b"])
      end

      it "appends multiple elements" do
        new_state = state.merge(messages: ["b", "c"])
        expect(new_state.messages).to eq(["a", "b", "c"])
      end
    end

    context "type: :merge" do
      it "merges the Hash" do
        new_state = state.merge(metadata: {y: 2})
        expect(new_state.metadata).to eq({x: 1, y: 2})
      end

      it "overwrites duplicate keys" do
        new_state = state.merge(metadata: {x: 99})
        expect(new_state.metadata).to eq({x: 99})
      end
    end

    it "preserves untouched fields" do
      new_state = state.merge(value: 99)
      expect(new_state.messages).to eq(["a"])
    end

    it "returns an instance of the same class" do
      expect(state.merge(value: 2)).to be_a(TestState)
    end

    it "raises ArgumentError when an unknown field key is passed (issue #154)" do
      expect { state.merge(nonexistent: 99) }
        .to raise_error(ArgumentError, /nonexistent/)
    end
  end

  describe "#to_h" do
    it "converts all fields to a Hash" do
      s = TestState.new(value: 5, messages: ["x"])
      h = s.to_h
      expect(h[:value]).to eq(5)
      expect(h[:messages]).to eq(["x"])
    end

    it "does not include internal workflow metadata" do
      s = TestState.new(value: 1)
      s.set_graph_metadata(thread_id: "t1", phase: :awaiting_foo)
      expect(s.to_h.keys).not_to include(:thread_id, :phase)
    end
  end

  describe "#set_graph_metadata" do
    it "stores thread_id" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "abc")
      expect(s.thread_id).to eq("abc")
    end

    it "stores phase" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t", phase: :awaiting_foo)
      expect(s.phase).to eq(:awaiting_foo)
    end

    it "nil thread_id is ignored" do
      s = TestState.new
      s.set_graph_metadata(thread_id: "t")
      s.set_graph_metadata(thread_id: nil)
      expect(s.thread_id).to eq("t")
    end

    it "nil phase is ignored" do
      s = TestState.new
      s.set_graph_metadata(phase: :some_node)
      s.set_graph_metadata(phase: nil)
      expect(s.phase).to eq(:some_node)
    end
  end

  describe "#phase" do
    it "returns :__end__ for a fresh state" do
      expect(TestState.new.phase).to eq(:__end__)
    end

    it "returns the phase set via set_graph_metadata" do
      s = TestState.new
      s.set_graph_metadata(phase: :awaiting_review)
      expect(s.phase).to eq(:awaiting_review)
    end
  end

  describe "#halted?" do
    it "returns false for a fresh (unstarted) state" do
      expect(TestState.new.halted?).to be(false)
    end

    it "returns true when phase is not :__end__" do
      s = TestState.new
      s.set_graph_metadata(phase: :awaiting_foo)
      expect(s.halted?).to be(true)
    end

    it "returns false when phase is :__end__" do
      s = TestState.new
      s.set_graph_metadata(phase: :__end__)
      expect(s.halted?).to be(false)
    end
  end

  describe "#merge preserves internal workflow metadata" do
    it "carries thread_id and phase through merge" do
      s = TestState.new(value: 1)
      s.set_graph_metadata(thread_id: "t1", phase: :awaiting_send)
      s2 = s.merge(value: 99)
      expect(s2.thread_id).to eq("t1")
      expect(s2.phase).to eq(:awaiting_send)
    end
  end

  describe ".field mutable default guard (Issue #122)" do
    it "raises ArgumentError when default is a bare Array" do
      expect do
        Class.new do
          include Phronomy::WorkflowContext

          field :tags, default: []
        end
      end.to raise_error(ArgumentError, /Mutable default.*tags.*Proc/)
    end

    it "raises ArgumentError when default is a bare Hash" do
      expect do
        Class.new do
          include Phronomy::WorkflowContext

          field :meta, default: {}
        end
      end.to raise_error(ArgumentError, /Mutable default.*meta.*Proc/)
    end

    it "accepts a Proc default that returns an Array" do
      klass = Class.new do
        include Phronomy::WorkflowContext

        field :tags, default: -> { [] }
      end
      ctx1 = klass.new
      ctx2 = klass.new
      ctx1.tags << "urgent"
      expect(ctx2.tags).to be_empty
    end

    it "accepts nil default without error" do
      expect do
        Class.new do
          include Phronomy::WorkflowContext

          field :value
        end
      end.not_to raise_error
    end
  end

  describe "unknown field detection in initialize (issue #121)" do
    let(:klass) do
      Class.new do
        include Phronomy::WorkflowContext

        field :score, default: 0
        field :name, default: "anon"
      end
    end

    it "raises ArgumentError for an unknown key (typo scenario)" do
      expect { klass.new(scor: 10) }
        .to raise_error(ArgumentError, /Unknown WorkflowContext field.*scor/)
    end

    it "raises ArgumentError listing all unknown keys" do
      expect { klass.new(foo: 1, bar: 2) }
        .to raise_error(ArgumentError, /foo/)
    end

    it "does not raise when all keys are declared fields" do
      expect { klass.new(score: 42, name: "Alice") }.not_to raise_error
    end

    it "does not raise when no keys are provided (all defaults)" do
      expect { klass.new }.not_to raise_error
    end
  end

  describe "deep copy isolation in merge (issue #123)" do
    let(:klass) do
      Class.new do
        include Phronomy::WorkflowContext

        field :tags, type: :replace, default: -> { [] }
        field :meta, type: :replace, default: -> { {} }
        field :count, type: :replace, default: 0
      end
    end

    it "does not share Array references between old and new context after merge" do
      old_ctx = klass.new(tags: ["a", "b"], count: 1)
      new_ctx = old_ctx.merge(count: 2)

      # Mutating new_ctx.tags must not affect old_ctx.tags
      new_ctx.tags << "c"
      expect(old_ctx.tags).to eq(["a", "b"])
    end

    it "does not share Hash references between old and new context after merge" do
      old_ctx = klass.new(meta: {key: "v"}, count: 1)
      new_ctx = old_ctx.merge(count: 2)

      new_ctx.meta[:extra] = "x"
      expect(old_ctx.meta).to eq({key: "v"})
    end

    it "deep-duplicates nested hashes inside arrays" do
      old_ctx = klass.new(tags: [{name: "a"}], count: 1)
      new_ctx = old_ctx.merge(count: 2)

      new_ctx.tags.first[:name] = "mutated"
      expect(old_ctx.tags.first[:name]).to eq("a")
    end

    it "still allows updating fields with new values via merge" do
      old_ctx = klass.new(tags: ["a"], count: 0)
      new_ctx = old_ctx.merge(tags: ["b"], count: 1)
      expect(new_ctx.tags).to eq(["b"])
      expect(new_ctx.count).to eq(1)
      expect(old_ctx.tags).to eq(["a"])
    end
  end

  describe "#merge with non-dupable field values (issue #156)" do
    let(:klass) do
      Class.new do
        include Phronomy::WorkflowContext
        field :callback, type: :replace, default: nil
      end
    end

    it "does not raise TypeError when a non-dupable object (Method) is stored in a field" do
      m = method(:puts)  # Method objects raise TypeError on dup
      ctx = klass.new(callback: m)
      expect { ctx.merge({}) }.not_to raise_error
    end

    it "returns the original object when dup raises TypeError" do
      m = method(:puts)
      ctx = klass.new(callback: m)
      new_ctx = ctx.merge({})
      expect(new_ctx.callback).to be(m)
    end
  end
end
