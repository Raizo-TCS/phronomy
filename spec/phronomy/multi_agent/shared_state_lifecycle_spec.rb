# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "SharedState default member lifetime" do
  let(:members) { [] }
  let(:member_class) do
    captured = members
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "shared-state-member-lifetime", version: 1
      model "offline-model"

      define_method(:initialize) do |**options|
        super(**options)
        captured << self
      end
    end
  end
  let(:team_class) do
    member = member_class
    Class.new(Phronomy::MultiAgent::SharedState) do
      member member
      max_cycles 2
    end
  end
  let(:failure) { nil }

  def use_adapter(&response)
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        response.call(request)
      end
      protected :perform_complete
    end
    Phronomy.configure { |configuration| configuration.llm_adapter = adapter.new }
  end

  def expect_released(agents)
    agents.each do |agent|
      expect(agent.class.get(agent.agent_id)).to be_nil
      expect { agent.transcript }.to raise_error(Phronomy::AgentUnloadedError)
    end
  end

  before do
    error = failure
    use_adapter do |_request|
      raise error if error

      Phronomy::LLMAdapter::Response.new(content: "done", finish_reason: :stop)
    end
  end

  it "releases every completed member across repeated invocations and cycles" do
    coordinator = team_class.new
    3.times do
      expect(coordinator.invoke("Review")).to eq(output: [], cycles: 2, terminated_by: :max_cycles)
      expect_released(members)
    end
    expect(members.size).to eq(6)
  end

  it "releases the completed member before early termination and aggregation" do
    team_class.terminate_when do |_store|
      expect_released(members)
      true
    end
    team_class.aggregate do |_store|
      expect_released(members)
      :summary
    end

    expect(team_class.new.invoke("Review")).to eq(output: :summary, cycles: 1, terminated_by: :terminate_when)
    expect(members.size).to eq(1)
  end

  it "releases the completed member when the coordination deadline ends the cycle" do
    team_class.timeout(0)

    expect(team_class.new.invoke("Review")).to eq(output: [], cycles: 1, terminated_by: :timeout)
    expect(members.size).to eq(1)
    expect_released(members)
  end

  context "when the member invocation fails" do
    let(:failure) { IOError.new("provider failed") }

    it "releases the member and preserves the original failure" do
      expect { team_class.new.invoke("Review") }.to raise_error { |error| expect(error).to equal(failure) }
      expect(members.size).to eq(1)
      expect_released(members)
    end

    it "keeps both failures and the member handle when release also fails" do
      release_failure = IOError.new("release failed")
      member_class.define_method(:unload!) { raise release_failure }

      expect { team_class.new.invoke("Review") }
        .to raise_error(Phronomy::MultiAgent::SharedState::MemberLifecycleError) { |error|
          expect(error.reason).to eq(:release_failed)
          expect(error.agent).to equal(members.fetch(0))
          expect(error.primary_error).to equal(failure)
          expect(error.release_error).to equal(release_failure)
          expect(error.cause).to equal(failure)
        }
      expect(members.size).to eq(1)
      expect(member_class.get(members.first.agent_id)).to equal(members.first)
    end
  end

  it "releases members before an aggregation failure" do
    failure = IOError.new("aggregation failed")
    team_class.aggregate { |_store| raise failure }

    expect { team_class.new.invoke("Review") }.to raise_error { |error| expect(error).to equal(failure) }
    expect(members.size).to eq(2)
    expect_released(members)
  end

  it "stops coordination and preserves the successful result when release fails" do
    release_failure = IOError.new("release failed")
    aggregated = false
    member_class.define_method(:unload!) { raise release_failure }
    team_class.aggregate { |_store| aggregated = true }

    expect { team_class.new.invoke("Review") }
      .to raise_error(Phronomy::MultiAgent::SharedState::MemberLifecycleError) { |error|
        expect(error.reason).to eq(:release_failed)
        expect(error.agent).to equal(members.fetch(0))
        expect(error.result.fetch(:output)).to eq("done")
        expect(error.primary_error).to be_nil
        expect(error.release_error).to equal(release_failure)
        expect(error.cause).to equal(release_failure)
      }
    expect(members.size).to eq(1)
    expect(aggregated).to be(false)
    expect(member_class.get(members.first.agent_id)).to equal(members.first)
  end

  it "preserves a member whose custom invoke returns suspended without continuing coordination" do
    suspended = {suspended: true, execution_id: "pending-execution"}
    member_class.define_method(:invoke) { |_input| suspended }
    aggregated = false
    team_class.aggregate { |_store| aggregated = true }

    expect { team_class.new.invoke("Review") }
      .to raise_error(Phronomy::MultiAgent::SharedState::MemberLifecycleError) { |error|
        expect(error.reason).to eq(:suspended)
        expect(error.agent).to equal(members.fetch(0))
        expect(error.result).to equal(suspended)
      }
    expect(members.size).to eq(1)
    expect(aggregated).to be(false)
    expect(member_class.get(members.first.agent_id)).to equal(members.first)
  end

  it "keeps a normal approval wait live and releases the member only after its reply" do
    requests = Queue.new
    captured = members
    effects = []
    aggregated = false
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "approved_record"
      description "Record an approved finding"
      requires_approval true
      execution_mode :cooperative
      define_method(:execute) do
        effects << :recorded
        "recorded"
      end
    end
    member_class.tools(tool => nil)
    member_class.define_method(:initialize) do |**options|
      super(**options, on_event: ->(event) { requests << event.payload.fetch(:request) if event.type == :approval_required })
      captured << self
    end
    team_class.max_cycles(1)
    team_class.aggregate do |_store|
      aggregated = true
      :summary
    end
    responses = [
      Phronomy::LLMAdapter::Response.new(tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "record-1", name: "approved_record", arguments: {})
      ], finish_reason: :tool_calls),
      Phronomy::LLMAdapter::Response.new(content: "done", finish_reason: :stop)
    ]
    use_adapter { |_request| responses.shift || raise("unexpected LLM request") }
    coordinator = Thread.new { team_class.new.invoke("Review") }
    request = Timeout.timeout(5) { requests.pop }
    agent = members.fetch(0)

    expect(coordinator).to be_alive
    expect(member_class.get(agent.agent_id)).to equal(agent)
    expect(effects).to eq([])
    expect(aggregated).to be(false)
    agent.approve_async(request.execution_id, approval_request_id: request.id, approved: true).wait_result(timeout: 5)

    expect(Timeout.timeout(5) { coordinator.value }).to eq(output: :summary, cycles: 1, terminated_by: :max_cycles)
    expect(effects).to eq([:recorded])
    expect(aggregated).to be(true)
    expect_released(members)
  ensure
    if coordinator&.alive?
      agent&.cancel_async(request.execution_id)&.wait_result(timeout: 5) if request
      coordinator.join(5)
      coordinator.kill if coordinator.alive?
    end
  end
end
