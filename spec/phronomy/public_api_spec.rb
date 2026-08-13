# frozen_string_literal: true

RSpec.describe "Public API compatibility (Stable APIs)" do
  describe "Phronomy::Agent::Base" do
    subject { Phronomy::Agent::Base }

    it "exposes the supported DSL class methods" do
      expect(subject).to respond_to(
        :model, :instructions, :tools, :max_iterations, :before_llm_input
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

  describe "Phronomy::Agent::Context::Capability::Base — execution_mode" do
    it "defaults to :offloaded when not declared" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "no-op"
        def execute
        end
      end
      expect(klass.execution_mode).to eq(:offloaded)
    end

    it "accepts :cooperative and :offloaded" do
      cooperative = Class.new(Phronomy::Agent::Context::Capability::Base) do
        execution_mode :cooperative
      end
      offloaded = Class.new(Phronomy::Agent::Context::Capability::Base) do
        execution_mode :offloaded
      end
      expect(cooperative.execution_mode).to eq(:cooperative)
      expect(offloaded.execution_mode).to eq(:offloaded)
    end

    it "rejects removed workload-specific execution modes" do
      %i[blocking_io cpu_bound external_process].each do |mode|
        expect {
          Class.new(Phronomy::Agent::Context::Capability::Base) { execution_mode mode }
        }.to raise_error(ArgumentError, /execution_mode/)
      end
    end
  end

  describe "Phronomy::Agent::Base — invoke_async" do
    it "exposes #invoke_async instance method" do
      expect(Phronomy::Agent::Base.public_instance_methods).to include(:invoke_async)
    end
  end

  describe "Phronomy::Runtime — offload API" do
    let(:runtime) { Phronomy::Runtime.instance }

    it "exposes #offload returning an OffloadPool" do
      expect(runtime.offload).to be_a(Phronomy::Concurrency::OffloadPool)
    end

    it "does not expose the removed #blocking_io API" do
      expect(runtime).not_to respond_to(:blocking_io)
    end
  end
end
