# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team-owned child lifetime" do
  include_context "durable coordination runtime"

  def child_ids(run)
    ([run.coordinator] + run.workers).map { |slot| slot.fetch("agent_id") }
  end

  def eventually(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      raise "condition did not become true" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.001
    end
  end

  def released?(id)
    Phronomy::Agent::Base.get(id).nil?
  rescue Phronomy::AgentBusyError
    false
  end

  def expect_released(team, run)
    eventually { child_ids(run).all? { |id| released?(id) } }
    expect(team.instance_variable_get(:@coordinator_classes)).not_to have_key(run.team_execution_id)
  end

  def two_task_responses
    calls = [["enqueue_task", {description: "one"}], ["enqueue_task", {description: "two"}],
      ["finalize", {}]].each_with_index.map do |(name, arguments), index|
      {"id" => "batch-#{index}", "type" => "function", "function" => {
        "name" => name, "arguments" => JSON.generate(arguments)
      }}
    end
    batch = {"id" => "tasks", "object" => "chat.completion", "model" => "stub-model",
             "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => nil,
                                                        "tool_calls" => calls}, "finish_reason" => "tool_calls"}]}
    [batch, "queued", "one-result", "two-result"]
  end

  it "releases completed runs on one executor without discarding their saved results" do
    Phronomy.configure { |config| config.offload_pool_size = 1 }
    team = team_class.create(persistence: store.multi_agent)
    5.times do |index|
      previous_ids = team.executions.map(&:team_execution_id)
      llm = LLMStub.activate(responses: team_responses)
      expect(team.invoke("plan-#{index}").first.fetch("result")).to eq("worker-result")
      run = team.executions.find { |entry| !previous_ids.include?(entry.team_execution_id) }
      expect(run).not_to be_nil
      expect_released(team, run)
      GC.start
      expect(team.instance_variable_get(:@coordinator_classes)).to be_empty
      expect(team.result(run.team_execution_id).fetch(:status)).to eq("completed")
      expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
      expect(llm.calls.size).to eq(4)
    end
    expect(team.executions.size).to eq(5)
    expect(team.executions.flat_map { |run| child_ids(run) }.all? { |id| released?(id) }).to be(true)
  end

  it "preserves the saved failure while releasing a rejected child's incarnation" do
    worker.max_iterations(-1)
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses)
    expect { team.invoke("plan") }.to raise_error(Phronomy::Error, /max_iterations/)
    run = team.executions.first
    expect(run.status).to eq("failed")
    expect_released(team, run)
    before = run.to_h
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /max_iterations/)
    expect(team.executions.first.to_h).to eq(before)
    expect(llm.calls.size).to eq(3)
  end

  it "retains active recovery state until a corrected scheduler commits a terminal result" do
    team_class.schedule { nil }
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses)
    expect { team.invoke("plan") }.to raise_error(Phronomy::ConfigurationError, /Scheduler/)
    run = team.executions.first
    coordinator = Phronomy::Agent::Base.get(run.coordinator.fetch("agent_id"))
    expect(coordinator).not_to be_nil
    expect(run.status).to eq("active")
    expect(team.instance_variable_get(:@coordinator_classes)).to have_key(run.team_execution_id)
    team_class.schedule { |available| available.first }
    expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect_released(team, team.executions.first)
    expect(llm.calls.size).to eq(4)
  end

  it "retains children when a terminal write is not confirmed and retries after recovery" do
    team = team_class.create(persistence: store.multi_agent)
    unavailable = true
    allow(store.backend).to receive(:replace_record).and_wrap_original do |original, context, resource, **options|
      if unavailable && resource.id == "team.executions" && !options.fetch(:entry).attributes.fetch(:active)
        raise IOError, "terminal commit unavailable"
      end
      original.call(context, resource, **options)
    end
    llm = LLMStub.activate(responses: team_responses)
    expect { team.invoke("plan") }.to raise_error(IOError, /terminal commit unavailable/)
    run = team.executions.first
    expect(run.status).to eq("active")
    expect(child_ids(run).map { |id| Phronomy::Agent::Base.get(id) }).not_to include(nil)
    expect(team.instance_variable_get(:@coordinator_classes)).to have_key(run.team_execution_id)
    unavailable = false
    expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect_released(team, team.executions.first)
    expect(llm.calls.size).to eq(4)
  end

  it "preserves terminal results through cleanup and reporting failures, and retries only on resume" do
    attempts = Queue.new
    failing = true
    worker.define_method(:unload_async) do
      attempts << agent_id
      failing ? Phronomy::TaskResult.failed(IOError.new("release storage unavailable")) : super()
    end
    logger = Object.new
    def logger.error(*) = raise(IOError, "report unavailable")
    def logger.warn(*) = nil
    Phronomy.configure { |config| config.logger = logger }
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses)
    expect(team.invoke("plan").first.fetch("result")).to eq("worker-result")
    run = team.executions.first
    expect(attempts.pop(timeout: 3)).to eq(run.workers.first.fetch("agent_id"))
    expect(team.instance_variable_get(:@coordinator_classes)).to be_empty
    expect(Phronomy::Agent::Base.get(run.workers.first.fetch("agent_id"))).not_to be_nil
    saved = run.to_h
    expect(team.result(run.team_execution_id).fetch(:status)).to eq("completed")
    expect(attempts).to be_empty
    failing = false
    expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect_released(team, run)
    expect(team.executions.first.to_h).to eq(saved)
    expect(llm.calls.size).to eq(4)
  end

  it "waits for every physical observation of a reused worker without delaying the saved result" do
    operations = Queue.new
    worker.define_method(:start_reserved_async) do |**options|
      source = super(**options)
      observer = Phronomy::Concurrency::PhysicalCompletionTask.deferred
      source.on_complete { |value, error| error ? observer.fail(error) : observer.complete(value) }
      source.on_physical_complete { operations << [self, observer] }
      observer
    end
    team = team_class.create(persistence: store.multi_agent)
    LLMStub.activate(responses: two_task_responses)
    expect(team.invoke("plan").map { |entry| entry.fetch("result") }).to eq(%w[one-result two-result])
    first_child, first = operations.pop(timeout: 3)
    second_child, second = operations.pop(timeout: 3)
    expect(second_child).to equal(first_child)
    run = team.executions.first
    expect(run.status).to eq("completed")
    expect(Phronomy::Agent::Base.get(first_child.agent_id)).to equal(first_child)
    second.mark_physical_complete!
    expect(Phronomy::Agent::Base.get(first_child.agent_id)).to equal(first_child)
    first.mark_physical_complete!
    expect_released(team, run)
  ensure
    first&.mark_physical_complete!
    second&.mark_physical_complete!
  end

  it "does not delay logical cancellation for an executing provider or release that owner early" do
    operations, entered, release = Queue.new, Queue.new, Queue.new
    worker.define_method(:start_reserved_async) do |**options|
      super(**options).tap { |operation| operations << [self, operation] }
    end
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses)
    allow(llm).to receive(:handle).and_wrap_original do |original, request|
      if JSON.parse(request.body).fetch("messages").any? { |message| message["role"] == "user" && message["content"] == "task-one" }
        entered << true
        release.pop(timeout: 3)
      end
      original.call(request)
    end
    turn = Thread.new do
      team.invoke("plan")
    rescue => error
      error
    end
    child, observation = operations.pop(timeout: 3)
    entered.pop(timeout: 3)
    observation.cancel!
    expect(turn.join(2)).not_to be_nil
    expect(turn.value).to be_a(Phronomy::CancellationError)
    run = team.executions.first
    expect(run.status).to eq("cancelled")
    expect(observation).not_to be_physical_complete
    expect(Phronomy::Agent::Base.get(child.agent_id)).to equal(child)
    release << true
    expect_released(team, run)
  ensure
    release&.push(true)
    turn&.join(3)
  end

  it "keeps a child approval live until the answer and then retires the completed run" do
    requests = Queue.new
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "team_approved_read"
      description "Read after approval"
      requires_approval true
      def execute = "approved"
    end
    worker.tools(tool => nil)
    team = team_class.create(persistence: store.multi_agent,
      on_event: ->(event) { requests << event.payload.fetch(:request) if event.type == :approval_required })
    LLMStub.activate(responses: team_responses.take(3) + [LLMStub.tool_call_response("team_approved_read", {}), "approved-result"])
    expect { team.invoke("plan") }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /approval/)
    request = requests.pop(timeout: 3)
    run = team.executions.first
    child = Phronomy::Agent::Base.get(run.workers.first.fetch("agent_id"))
    expect(run.status).to eq("active")
    expect(child).not_to be_nil
    expect(team.instance_variable_get(:@coordinator_classes)).to have_key(run.team_execution_id)
    child.approve_async(request.execution_id, approval_request_id: request.id).wait_result(timeout: 3)
    expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("approved-result")
    expect_released(team, team.executions.first)
  end

  it "does not release a different-store owner found under a saved child identity" do
    team = team_class.create(persistence: store.multi_agent)
    LLMStub.activate(responses: team_responses)
    expect(team.invoke("plan").first.fetch("result")).to eq("worker-result")
    run = team.executions.first
    expect_released(team, run)
    other = worker.create(agent_id: run.workers.first.fetch("agent_id"))
    diagnostics = []
    logger = Object.new
    logger.define_singleton_method(:error) { |message| diagnostics << message }
    def logger.warn(*) = nil
    Phronomy.configure { |config| config.logger = logger }

    expect(team.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect(worker.get(other.agent_id)).to equal(other)
    expect(diagnostics.join).to include("Persistence mismatch", other.agent_id)
    other.add_knowledge("independent owner")
    expect(other.unload!).to be(true)
  end

  it "does not report an already accepted release as a cancellation cleanup failure" do
    messages = []
    logger = Object.new
    logger.define_singleton_method(:error) { |message| messages << message }
    def logger.warn(*) = nil
    Phronomy.configure { |config| config.logger = logger }
    team_class.schedule { nil }
    team = team_class.create(persistence: store.multi_agent)
    LLMStub.activate(responses: team_responses)
    expect { team.invoke("plan") }.to raise_error(Phronomy::ConfigurationError)
    run = team.executions.first
    team.cancel(run.team_execution_id)

    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::CancellationError)
    expect_released(team, team.executions.first)
    expect(messages).to be_empty
  end
end
