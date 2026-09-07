# frozen_string_literal: true

require_relative "../../../integration/support/llm_stub"

RSpec.shared_context "durable coordination runtime" do
  # Captures committed DurableRecords, then materializes them in a new backend
  # and Runtime. This models F4 without retaining any Agent/Task/Class handles.
  class CoordinationFaultStore < Phronomy::Persistence::InMemory
    attr_accessor :after_commit, :before_io

    def initialize
      super
      owner = self
      {contents => :fetch, executions => :load}.each do |repository, operation|
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

    def transaction
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

    def snapshot = synchronize { Marshal.load(Marshal.dump(state)) }

    def self.restore(snapshot)
      new.tap { |store| store.synchronize { store.state.replace(Marshal.load(Marshal.dump(snapshot))) } }
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
      c.default_output_reserve = 4096
      c.event_loop_stop_grace_seconds = 0.5
    }
  end
  after { LLMStub.deactivate }

  def team_responses
    [LLMStub.tool_call_response("enqueue_task", {description: "task-one"}),
      LLMStub.tool_call_response("finalize", {}), "queued", "worker-result"]
  end

  def reboot(snapshot)
    Phronomy.reset_runtime!
    CoordinationFaultStore.restore(snapshot)
  end
end
