# frozen_string_literal: true

require "spec_helper"
require "rantly/rspec_extensions"

RSpec.describe "WorkflowContext property-based tests" do
  # A fixed context class that covers all three field merge strategies.
  let(:ctx_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, type: :replace, default: 0
      field :tags, type: :append, default: -> { [] }
      field :meta, type: :merge, default: -> { {} }
    end
  end

  # P1: merge({}) is the identity operation — all user field values are preserved.
  it "merge({}) preserves all user field values (identity)" do
    property_of {
      n = integer(1000)
      tags = array(3) { sized(4) { string(:alpha) } }
      [n, tags]
    }.check do |(n, tags)|
      ctx = ctx_class.new(value: n, tags: tags)
      merged = ctx.merge({})
      expect(merged.value).to eq(n)
      expect(merged.tags).to eq(tags)
    end
  end

  # P2: merging a :replace field never modifies :append or :merge fields.
  it "merging :replace field does not affect other fields" do
    property_of {
      old_val = integer(500)
      new_val = integer(500)
      tag = sized(4) { string(:alpha) }
      [old_val, new_val, tag]
    }.check do |(old_val, new_val, tag)|
      ctx = ctx_class.new(value: old_val, tags: [tag])
      merged = ctx.merge(value: new_val)
      expect(merged.value).to eq(new_val)
      expect(merged.tags).to eq([tag])
    end
  end

  # P3: :append field accumulates items in strict insertion order across N merges.
  it ":append field preserves insertion order across sequential merges" do
    property_of {
      n = range(1, 8)
      items = array(n) { sized(4) { string(:alpha) } }
      items
    }.check do |items|
      ctx = ctx_class.new
      result = items.reduce(ctx) { |acc, item| acc.merge(tags: [item]) }
      expect(result.tags).to eq(items)
    end
  end

  # P4: merge with any undeclared key always raises ArgumentError naming the key.
  it "merge with an undeclared key raises ArgumentError" do
    property_of {
      # Prefix guarantees the key never collides with :value, :tags, or :meta.
      "unknown_" + sized(4) { string(:alpha) }
    }.check do |bad_key|
      ctx = ctx_class.new
      expect { ctx.merge(bad_key.to_sym => 42) }
        .to raise_error(ArgumentError, /#{Regexp.escape(bad_key)}/)
    end
  end

  # P5: graph metadata (workflow_instance_id) is preserved through any merge.
  it "workflow_instance_id metadata is preserved after merge" do
    property_of {
      n = integer(500)
      tid = "tid-" + sized(4) { string(:lower) }
      [n, tid]
    }.check do |(n, tid)|
      ctx = ctx_class.new
      ctx.set_graph_metadata(workflow_instance_id: tid)
      merged = ctx.merge(value: n)
      expect(merged.workflow_instance_id).to eq(tid)
    end
  end

  # P6: merge is non-destructive — the original context is never mutated.
  it "merge does not mutate the original context" do
    property_of { integer(1000) }.check do |n|
      ctx = ctx_class.new(value: 0)
      ctx.merge(value: n)
      expect(ctx.value).to eq(0)
    end
  end
end
