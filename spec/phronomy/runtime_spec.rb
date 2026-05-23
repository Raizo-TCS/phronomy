# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Runtime do
  describe ".instance" do
    it "returns the same object on repeated calls" do
      expect(described_class.instance).to be(described_class.instance)
    end

    it "returns a Runtime" do
      expect(described_class.instance).to be_a(described_class)
    end
  end

  describe ".instance=" do
    after do
      # Reset to a fresh instance after the test
      described_class.instance_variable_set(:@instance, nil)
    end

    it "replaces the shared instance" do
      custom = described_class.new
      described_class.instance = custom
      expect(described_class.instance).to be(custom)
    end
  end

  describe "#task_group" do
    it "returns a TaskGroup" do
      group = described_class.instance.task_group
      expect(group).to be_a(Phronomy::TaskGroup)
    end

    it "passes the limit to the TaskGroup" do
      group = described_class.instance.task_group(limit: 3)
      expect(group.instance_variable_get(:@limit)).to eq(3)
    end
  end

  describe "#spawn" do
    it "returns a Task" do
      task = described_class.instance.spawn { 7 }
      expect(task).to be_a(Phronomy::Task)
      expect(task.await).to eq(7)
    end

    it "accepts an optional name" do
      task = described_class.instance.spawn(name: "rt-task") { :ok }
      expect(task.name).to eq("rt-task")
      task.await
    end
  end
end
