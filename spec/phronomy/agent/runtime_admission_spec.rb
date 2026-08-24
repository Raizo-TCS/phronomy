# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent Runtime admission" do
  let(:persistence) { Phronomy::Persistence::InMemory.new }

  it "rejects a competing top-level invoke on EventLoop before Persistence admission" do
    entered = Queue.new
    release = Queue.new

    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "runtime-admission-test", version: 1
      model "local-model"
      instructions "Test"

      define_method(:extract_message) do |input|
        if input == "first" && !defined?(@_acs12_blocked_once)
          @_acs12_blocked_once = true
          entered << true
          release.pop
          raise ArgumentError, "stop first request before durable admission"
        end
        super(input)
      end
    end

    agent = agent_class.create(agent_id: "agent-a", persistence: persistence)
    allow(persistence.executions).to receive(:create_active).and_call_original

    first = agent.invoke_async("first")
    expect(entered.pop).to be true

    second = agent.invoke_async("second")
    expect {
      second.wait_result(timeout: 1)
    }.to raise_error(Phronomy::AgentBusyError)

    # The second request was rejected by process-local EventLoop admission, and
    # the first worker is still blocked before Persistence admission.
    expect(persistence.executions).not_to have_received(:create_active)

    release << true
    expect {
      first.wait_result(timeout: 1)
    }.to raise_error(ArgumentError, /stop first request/)
    expect(persistence.executions).not_to have_received(:create_active)
  ensure
    release << true if defined?(release) && release.empty?
  end

  it "releases a known pre-durable failure so a later request can be admitted" do
    failures = 0
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "runtime-admission-release-test", version: 1
      model "local-model"
      instructions "Test"

      define_method(:extract_message) do |input|
        if failures.zero?
          failures += 1
          raise ArgumentError, "known pre-durable failure"
        end
        raise ArgumentError, "second request reached worker"
      end
    end

    agent = agent_class.create(agent_id: "agent-a", persistence: persistence)

    expect {
      agent.invoke_async("first").wait_result(timeout: 1)
    }.to raise_error(ArgumentError, /known pre-durable failure/)

    # If the first admission leaked, this would raise AgentBusyError instead of
    # reaching the second worker-side extract_message call.
    expect {
      agent.invoke_async("second").wait_result(timeout: 1)
    }.to raise_error(ArgumentError, /second request reached worker/)
  end

  it "keeps the Runtime slot fail-closed when durable state reports an existing nonterminal execution" do
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "runtime-admission-durable-busy-test", version: 1
      model "local-model"
      instructions "Test"
    end

    agent = agent_class.create(agent_id: "agent-a", persistence: persistence)
    calls = 0
    allow(persistence.executions).to receive(:create_active) do |_execution|
      calls += 1
      raise Phronomy::AgentBusyError, "durable execution already exists"
    end

    expect {
      agent.invoke_async("first").wait_result(timeout: 1)
    }.to raise_error(Phronomy::AgentBusyError, /durable execution already exists/)
    expect(calls).to eq(1)

    # The durable busy result represents a nonterminal logical Execution that
    # this Runtime has not rehydrated. A second start must fail at Runtime
    # admission instead of probing Persistence again.
    expect {
      agent.invoke_async("second").wait_result(timeout: 1)
    }.to raise_error(Phronomy::AgentBusyError)
    expect(calls).to eq(1)
  end

  it "places Runtime admission before the initial Offload/Persistence operation" do
    source = File.read(
      File.expand_path("../../../lib/phronomy/agent/execution_coordinator.rb", __dir__)
    )
    section = source
      .split("def begin_start_on_event_loop", 2)
      .fetch(1)
      .split("def perform_initial_preparation", 2)
      .first

    admission_index = section.index("admit_agent_execution")
    post_admission_owner_check = section.index("__assert_live_agent!", admission_index)
    submit_index = section.index("runtime.offload.submit")

    expect(admission_index).to be < post_admission_owner_check
    expect(post_admission_owner_check).to be < submit_index
  end

  it "keeps Persistence create_active as the durable second line of defense" do
    source = File.read(
      File.expand_path("../../../lib/phronomy/agent/execution_coordinator.rb", __dir__)
    )

    expect(source).to include("tx.executions.create_active(execution)")
  end

  it "keeps Runtime shutdown waiting through Agent durability transitions" do
    event_loop_source = File.read(
      File.expand_path("../../../lib/phronomy/engine/event_loop.rb", __dir__)
    )
    coordinator_source = File.read(
      File.expand_path("../../../lib/phronomy/agent/execution_coordinator.rb", __dir__)
    )

    idle_helper = event_loop_source
      .split("def agent_admission_transition_in_progress_locked?", 2)
      .fetch(1)
      .split(/^    def /, 2)
      .first
    expect(idle_helper).to include(
      "%i[admitting executing resuming cancelling terminalizing]"
    )
    expect(idle_helper).not_to include("suspended recovery_required")

    resume = coordinator_source
      .split("def begin_resume_on_event_loop", 2)
      .fetch(1)
      .split("def perform_resume_commit", 2)
      .first
    expect(resume.index("state: :resuming")).to be <
      resume.index("runtime.offload.submit")

    terminal = coordinator_source
      .split("def submit_terminal_operation", 2)
      .fetch(1)
      .split("def terminal_view", 2)
      .first
    expect(terminal.index("state: :terminalizing")).to be <
      terminal.index("runtime.offload.submit")
  end

  it "returns false when __agent_execution_admitted? is queried for an unknown agent" do
    result = Phronomy::Runtime.instance.__agent_execution_admitted?("unknown-agent-id")
    expect(result).to be false
  end

  it "returns false when __agent_execution_admitted? is called with nil" do
    result = Phronomy::Runtime.instance.__agent_execution_admitted?(nil)
    expect(result).to be false
  end

  it "returns false when __agent_execution_admitted? is called on a fresh Runtime before any EventLoop exists" do
    runtime = Phronomy::Runtime.new
    result = runtime.__agent_execution_admitted?("any-agent-id")
    expect(result).to be false
  ensure
    runtime&.shutdown(timeout: 2)
  end

  it "raises AgentBusyError when purge! is attempted while an execution is in progress" do
    entered = Queue.new
    release = Queue.new

    busy_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "busy-purge-test-agent", version: 1
      model "local-model"
      instructions "busy"

      define_method(:extract_message) do |input|
        entered.push(true)
        release.pop
        super(input)
      end
    end

    agent = busy_class.create(agent_id: "busy-purge-agent", persistence: persistence)
    agent.invoke_async("work")
    entered.pop

    expect {
      agent.purge!
    }.to raise_error(Phronomy::AgentBusyError)

    release.push(true)
  ensure
    begin
      Phronomy.reset_runtime!
    rescue
      nil
    end
  end
end
