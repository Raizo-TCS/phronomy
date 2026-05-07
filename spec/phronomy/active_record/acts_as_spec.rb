# frozen_string_literal: true

require "spec_helper"

# Simulate the AR model infrastructure without Rails/ActiveRecord.
# We test that acts_as_phronomy_* adds the right methods and includes the right modules.

RSpec.describe Phronomy::ActiveRecord::ActsAs do
  # ---- acts_as_phronomy_message -----------------------------------------------

  describe "acts_as_phronomy_message" do
    let(:model_class) do
      Class.new do
        def self.validates(attr, **opts)
        end

        include Phronomy::ActiveRecord::ActsAs

        acts_as_phronomy_message
      end
    end

    it "includes Phronomy::ActiveRecord::Message" do
      expect(model_class.ancestors).to include(Phronomy::ActiveRecord::Message)
    end

    it "adds a .phronomy_memory factory method" do
      expect(model_class).to respond_to(:phronomy_memory)
    end

    it "returns a Memory::ActiveRecordMemory instance from .phronomy_memory" do
      mem = model_class.phronomy_memory
      expect(mem).to be_a(Phronomy::Memory::ActiveRecordMemory)
    end

    it "the returned memory uses the model class" do
      mem = model_class.phronomy_memory
      expect(mem.instance_variable_get(:@model_class)).to eq(model_class)
    end
  end
end
