# frozen_string_literal: true

# Trace context task tree (Issue #277).
#
# Verifies that InvocationContext carries task_id and parent_task_id
# attributes that allow tracers to construct a parent-child span tree.
RSpec.describe "Trace context task tree (Issue #277)" do
  describe "InvocationContext task tree attributes" do
    it "accepts task_id and parent_task_id at construction" do
      ctx = Phronomy::InvocationContext.new(
        task_id: "task-abc",
        parent_task_id: "task-parent"
      )
      expect(ctx.task_id).to eq("task-abc")
      expect(ctx.parent_task_id).to eq("task-parent")
    end

    it "defaults task_id and parent_task_id to nil" do
      ctx = Phronomy::InvocationContext.new
      expect(ctx.task_id).to be_nil
      expect(ctx.parent_task_id).to be_nil
    end

    it "propagates task_id and parent_task_id through #merge" do
      parent = Phronomy::InvocationContext.new(task_id: "root")
      child  = parent.merge(task_id: "child-1", parent_task_id: "root")

      expect(child.task_id).to eq("child-1")
      expect(child.parent_task_id).to eq("root")
      # Other attributes are preserved
      expect(child.thread_id).to be_nil
    end

    it "preserves existing task_id when merge does not override it" do
      ctx    = Phronomy::InvocationContext.new(task_id: "task-xyz")
      merged = ctx.merge(thread_id: "t-1")

      expect(merged.task_id).to eq("task-xyz")
    end

    it "allows overriding parent_task_id independently" do
      ctx    = Phronomy::InvocationContext.new(task_id: "t1", parent_task_id: "p0")
      merged = ctx.merge(parent_task_id: "p1")

      expect(merged.task_id).to eq("t1")
      expect(merged.parent_task_id).to eq("p1")
    end

    it "supports building a parent → child chain with distinct task_ids" do
      root  = Phronomy::InvocationContext.new(task_id: "root")
      child = root.merge(task_id: "child", parent_task_id: root.task_id)

      expect(child.parent_task_id).to eq(root.task_id)
    end
  end
end
