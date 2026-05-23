# frozen_string_literal: true

# Public API compatibility snapshot (Issue #236).
#
# Verifies that every Stable-tagged constant listed in README.md exposes the
# expected public methods. If any method is accidentally removed or renamed,
# this spec will fail with a clear message before the change reaches CI.
#
# To add a new Stable API: append an expectation below and commit the diff as
# part of the PR that promotes the API to Stable.

RSpec.describe "Public API compatibility (Stable APIs)" do
  describe "Phronomy::Agent::Base" do
    subject { Phronomy::Agent::Base }

    it "exposes DSL class methods" do
      expect(subject).to respond_to(:model, :instructions, :tools, :invoke_timeout, :max_parallel_tools, :before_completion)
    end

    it "exposes #invoke instance method" do
      expect(subject.public_instance_methods).to include(:invoke)
    end
  end

  describe "Phronomy::Workflow" do
    subject { Phronomy::Workflow }

    it "exposes .define class method" do
      expect(subject).to respond_to(:define)
    end

    it "exposes instance methods: invoke, resume, send_event" do
      expect(subject.public_instance_methods).to include(:invoke, :resume, :send_event)
    end
  end

  describe "Phronomy::WorkflowContext (includable module)" do
    subject do
      Class.new do
        include Phronomy::WorkflowContext
      end
    end

    it "exposes .field and .fields class methods after include" do
      expect(subject).to respond_to(:field, :fields)
    end
  end

  describe "Phronomy::Tool::Base" do
    subject { Phronomy::Tool::Base }

    it "exposes DSL class methods: description, param, on_error" do
      expect(subject).to respond_to(:description, :param, :on_error)
    end

    it "exposes instance methods: call, params_schema, requires_approval?" do
      expect(subject.public_instance_methods).to include(:call, :params_schema, :requires_approval?)
    end
  end

  describe "Phronomy::OutputParser::Base" do
    subject { Phronomy::OutputParser::Base }

    it "exposes instance methods: parse, invoke" do
      expect(subject.public_instance_methods).to include(:parse, :invoke)
    end
  end

  describe "Phronomy::Tracing::Base" do
    subject { Phronomy::Tracing::Base }

    it "exposes instance methods: trace, start_span, finish_span" do
      expect(subject.public_instance_methods).to include(:trace, :start_span, :finish_span)
    end
  end

  describe "Phronomy::VectorStore::Base" do
    subject { Phronomy::VectorStore::Base }

    it "exposes instance methods: add, search, remove, clear" do
      expect(subject.public_instance_methods).to include(:add, :search, :remove, :clear)
    end
  end

  describe "Phronomy::CancellationToken" do
    subject { Phronomy::CancellationToken }

    it "exposes class method: timeout_after" do
      expect(subject).to respond_to(:timeout_after)
    end

    it "exposes instance methods: cancel!, cancelled?, raise_if_cancelled!" do
      expect(subject.public_instance_methods).to include(:cancel!, :cancelled?, :raise_if_cancelled!)
    end
  end
end
