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

    it "exposes the supported DSL class methods" do
      expect(subject).to respond_to(
        :model, :instructions, :tools, :max_iterations, :before_completion
      )
    end

    it "does not expose removed execution-policy DSL methods" do
      expect(subject).not_to respond_to(:retry_policy, :invoke_timeout, :max_parallel_tools)
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

  describe "Phronomy::Agent::Context::Capability::Base" do
    subject { Phronomy::Agent::Context::Capability::Base }

    it "exposes DSL class methods: description, param, on_error" do
      expect(subject).to respond_to(:description, :param, :on_error)
    end

    it "does not expose the removed generic Tool retry DSL" do
      expect(subject).not_to respond_to(:retry_on, :retry_policies)
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

    it "exposes instance methods: add, search, remove, clear, size" do
      expect(subject.public_instance_methods).to include(:add, :search, :remove, :clear, :size)
    end
  end

  describe "Phronomy::Concurrency::CancellationToken" do
    subject { Phronomy::Concurrency::CancellationToken }

    it "exposes class method: timeout_after" do
      expect(subject).to respond_to(:timeout_after)
    end

    it "exposes instance methods: cancel!, cancelled?, raise_if_cancelled!" do
      expect(subject.public_instance_methods).to include(:cancel!, :cancelled?, :raise_if_cancelled!)
    end
  end

  # --- Cooperative / Blocking distinction (Issue #278) ---

  describe "Phronomy::Agent::Context::Capability::Base — execution_mode" do
    it "defaults to :blocking_io when not declared" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "no-op"
        def execute
        end
      end
      expect(klass.execution_mode).to eq(:blocking_io)
    end

    it "accepts :cooperative as a valid execution_mode" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "no-op"
        execution_mode :cooperative
        def execute
        end
      end
      expect(klass.execution_mode).to eq(:cooperative)
    end

    it "raises ArgumentError for unknown execution_mode values" do
      expect {
        Class.new(Phronomy::Agent::Context::Capability::Base) do
          description "no-op"
          execution_mode :unknown_mode
          def execute
          end
        end
      }.to raise_error(ArgumentError, /execution_mode/)
    end
  end

  describe "Phronomy::Agent::Base — invoke_async" do
    it "exposes #invoke_async instance method" do
      expect(Phronomy::Agent::Base.public_instance_methods).to include(:invoke_async)
    end
  end

  describe "Phronomy::Runtime — blocking/cooperative API" do
    let(:runtime) { Phronomy::Runtime.instance }

    it "exposes #blocking_io returning a BlockingAdapterPool" do
      expect(runtime.blocking_io).to be_a(Phronomy::Concurrency::BlockingAdapterPool)
    end

    it "exposes #task_group returning a TaskGroup" do
      expect(runtime.task_group).to be_a(Phronomy::TaskGroup)
    end
  end
end
