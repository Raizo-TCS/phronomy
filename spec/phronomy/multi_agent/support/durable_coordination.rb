# frozen_string_literal: true

require_relative "../../../integration/support/llm_stub"

RSpec.shared_context "durable coordination runtime" do
  # Captures committed DurableRecords, then materializes them in a new backend
  # and Runtime. This models F4 without retaining any Agent/TaskResult/Class handles.
  class CoordinationFaultStore < Phronomy::Persistence
    attr_accessor :after_commit, :before_io
    attr_reader :agent, :multi_agent

    def initialize
      super(backend: Phronomy::Storage::Backends::InMemory.new(resources: Phronomy::PersistenceComposition::StorageSchema.resources))
      @agent = Phronomy::Agent::Store.new(coordinator: self, records: Phronomy::Agent::Persistence::Records)
      @multi_agent = Phronomy::MultiAgent::Store.new(coordinator: self, records: Phronomy::MultiAgent::Persistence::Records, agent_store: @agent)
      owner = self
      {@agent.contents => :fetch, @agent.executions => :load}.each do |repository, operation|
        repository.define_singleton_method(operation) do |*args|
          owner.check_io_thread!(operation)
          super(*args)
        end
      end
    end

    # The full F1/F4 matrix enforces the synchronous Persistence SPI boundary.
    # InMemory speed must not hide reads accidentally performed by EventLoop.
    def check_io_thread!(operation)
      if Phronomy::Runtime.instance.event_loop.current?
        raise "Persistence #{operation} must not run on EventLoop"
      end
      before_io&.call(operation)
    end

    def atomic
      check_io_thread!(:transaction)
      value = super { |tx| yield tx }
      hook = after_commit
      if hook && !Thread.current[:coordination_fault_hook]
        begin
          Thread.current[:coordination_fault_hook] = true
          hook.call(self)
        ensure
          Thread.current[:coordination_fault_hook] = nil
        end
      end
      value
    end

    def snapshot = backend.transaction { Marshal.load(Marshal.dump(backend.instance_variable_get(:@state))) }

    def self.restore(snapshot)
      new.tap { |store| store.backend.transaction { store.backend.instance_variable_get(:@state).replace(Marshal.load(Marshal.dump(snapshot))) } }
    end
  end

  let(:store) { CoordinationFaultStore.new }
  let(:worker) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "durable-worker", version: 1
      model "gpt-4o-mini"
      provider :openai
    end
  end
  let(:team_class) do
    child = worker
    Class.new(Phronomy::MultiAgent::TeamCoordinator) do
      team_definition id: "durable-team", version: 1
      coordinator_model "gpt-4o-mini"
      coordinator_provider :openai
      pool size: 1, agent: child
    end
  end
  let(:parent_class) do
    child = worker
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "durable-parent", version: 1
      model "gpt-4o-mini"
      provider :openai
      subagent :worker, child
    end
  end

  before do
    RubyLLM.configure { |c|
      c.openai_api_key = "test"
      c.openai_api_base = "https://example.test/v1"
    }
    Phronomy.configure { |c|
      c.event_loop_stop_grace_seconds = 0.5
    }
  end
  after { LLMStub.deactivate }

  def team_responses
    [LLMStub.tool_call_response("enqueue_task", {description: "task-one"}),
      LLMStub.tool_call_response("finalize", {}), "queued", "worker-result"]
  end

  # Inspect the phase and copy the checkpoint under the same backend lock.
  # Concurrent after_commit hooks must not replace an already chosen checkpoint.
  def unresolved_child_checkpoint(parent)
    captured = nil
    store.after_commit = proc do |backend|
      backend.backend.transaction do
        next if captured
        run = backend.agent.runs(parent.agent_id).first
        next unless run&.metadata&.dig("execution_extension", "state_ref")
        extension = backend.agent.contents.fetch_json(run.metadata.fetch("execution_extension").fetch("state_ref"))
        child_id = extension.fetch("children").first.fetch("execution_id")
        begin
          child = backend.agent.executions.load(child_id)
          captured = backend.snapshot if run.active? && run.phase == :dispatching_tools && child.phase == :calling_llm
        rescue Phronomy::Persistence::NotFoundError
          nil
        end
      end
    end
    LLMStub.activate(responses: [LLMStub.tool_call_response("dispatch_to_worker", {input: "job"}), "child", "parent"])
    parent.invoke("plan")
    raise "Unresolved child checkpoint was not captured" unless captured
    captured
  ensure
    store.after_commit = nil
  end

  def reboot(snapshot)
    Phronomy.reset_runtime!
    CoordinationFaultStore.restore(snapshot)
  end
end
