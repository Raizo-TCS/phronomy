# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolInvocation do
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

  let(:tool_class) do
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "send_message"
      description "Send a message"
      param :recipients, type: :array, desc: "Recipients"
      param :body, type: :string, desc: "Body"
      redact_params :body

      approval_facts do |arguments, _context|
        {
          recipient_count: arguments[:recipients].size,
          external_domain: "example.net"
        }
      end

      requires_approval do |request|
        request.facts[:recipient_count] > 10
      end

      def execute(recipients:, body:)
        "sent #{body.length} bytes to #{recipients.length} recipients"
      end
    end
  end

  let(:tool) { tool_class.new }
  let(:agent) { instance_double(Phronomy::Agent::Base) }
  let(:tool_call) do
    ToolCall.new(
      id: "call-1",
      name: "send_message",
      arguments: {"recipients" => Array.new(11, "a@example.net"), "body" => "secret"}
    )
  end

  subject(:invocation) do
    described_class.new(
      parent_agent_invocation_id: "agent-1",
      agent: agent,
      tool: tool,
      tool_call: tool_call,
      config: {},
      approval_context: {environment: :production}
    )
  end

  it "validates arguments before evaluating approval facts" do
    invocation.validate!
    outcome = invocation.send(:evaluate_authorization)

    expect(invocation.arguments).to include(body: "secret")
    expect(outcome.decision).to eq(:require_approval)
    expect(outcome.facts).to include(recipient_count: 11)
  end

  it "allows Agent policy to combine Tool facts with Application context" do
    policy = lambda do |request|
      if request.invocation_context[:environment] == :production &&
          request.facts[:recipient_count] > 10
        :reject
      else
        request.default_decision
      end
    end
    invocation = described_class.new(
      parent_agent_invocation_id: "agent-1",
      agent: agent,
      tool: tool,
      tool_call: tool_call,
      config: {},
      approval_policy: policy,
      approval_context: {environment: :production}
    )

    invocation.validate!
    outcome = invocation.send(:evaluate_authorization)

    expect(outcome.decision).to eq(:reject)
  end

  it "redacts sensitive arguments and String-valued facts from UI output" do
    invocation.validate!
    invocation.apply_fsm_action_result(invocation.send(:evaluate_authorization))

    expect(invocation.display_arguments[:body]).to eq("[REDACTED]")
    expect(invocation.display_facts[:recipient_count]).to eq(11)
    expect(invocation.display_facts[:external_domain]).to eq("[REDACTED]")
  end

  # ---------------------------------------------------------------------------
  # Branch coverage: constructor duck-typing, validate!, dispatchable?,
  # evaluate_authorization error paths, evaluate_facts, evaluate_default_decision
  # ---------------------------------------------------------------------------

  describe "constructor duck-typing" do
    it "accepts a tool_call without :id method" do
      stub = Struct.new(:name, :arguments).new("send_message", {"recipients" => [], "body" => "hi"})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: tool,
        tool_call: stub, config: {}
      )
      expect(inv.instance_variable_get(:@tool_call_id)).to be_nil
    end

    it "accepts a tool_call without :arguments method" do
      stub = Struct.new(:id, :name).new("call-2", "send_message")
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: tool,
        tool_call: stub, config: {}
      )
      expect(inv.instance_variable_get(:@raw_arguments)).to eq({})
    end

    it "uses :local origin when tool does not respond to tool_origin" do
      basic_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "basic"
        description "basic"
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "basic", {})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: basic_tool,
        tool_call: stub, config: {}
      )
      expect(inv.instance_variable_get(:@origin)).to eq(:local)
    end

    it "defaults approval_context to empty hash when nil" do
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: tool,
        tool_call: tool_call, config: {}, approval_context: nil
      )
      expect(inv.instance_variable_get(:@approval_context)).to eq({})
    end
  end

  describe "#validate!" do
    it "returns :completed status when schema validation fails with return_error policy" do
      err_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "err_tool"
        description "d"
        on_schema_error :return_error
        param :count, type: :integer, desc: "c"
        def execute(count:)
          count.to_s
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "err_tool", {"count" => "not_an_int"})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: err_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      expect(inv.instance_variable_get(:@status)).to eq(:completed)
    end

    it "returns :failed status when schema validation fails with :raise policy" do
      raise_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "raise_tool"
        description "d"
        on_schema_error :raise
        param :count, type: :integer, desc: "c"
        def execute(count:)
          count.to_s
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "raise_tool", {"count" => "bad"})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: raise_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      expect(inv.instance_variable_get(:@status)).to eq(:failed)
    end

    it "does not re-validate when already terminal" do
      invocation.validate!
      invocation.send(:apply_authorization_outcome,
        Phronomy::Agent::ToolInvocation::AuthorizationOutcome.new(
          error: RuntimeError.new("x"), cancelled: false
        ))
      expect(invocation).not_to receive(:validate_and_coerce)
      invocation.validate!
    end
  end

  describe "#dispatchable?" do
    it "returns true when queued and final_decision is :allow" do
      invocation.validate!
      invocation.send(:apply_authorization_outcome,
        Phronomy::Agent::ToolInvocation::AuthorizationOutcome.new(
          decision: :allow, facts: {}, reason: nil
        ))
      invocation.mark_queued!
      expect(invocation.dispatchable?).to be true
    end

    it "returns true when queued and approval was consumed" do
      invocation.validate!
      invocation.mark_awaiting_approval!
      invocation.mark_authorized!  # sets @approval_consumed = true
      invocation.mark_queued!
      expect(invocation.dispatchable?).to be true
    end

    it "returns false when not queued" do
      expect(invocation.dispatchable?).to be false
    end
  end

  describe "evaluate_authorization error paths" do
    it "returns :require_approval on TimeoutError" do
      # Set invocation to valid state directly without allow_any_instance_of
      invocation.instance_variable_set(:@status, :valid)
      invocation.instance_variable_set(:@arguments, {}.freeze)
      error = Phronomy::TimeoutError.new("timeout")
      outcome = invocation.send(:authorization_failure_outcome, error)
      expect(outcome.decision).to eq(:require_approval)
    end

    it "returns cancelled outcome on CancellationError" do
      error = Phronomy::CancellationError.new("cancelled")
      outcome = invocation.send(:authorization_failure_outcome, error)
      expect(outcome.cancelled).to be true
    end

    it "returns error outcome on unexpected error" do
      error = RuntimeError.new("boom")
      outcome = invocation.send(:authorization_failure_outcome, error)
      expect(outcome.error).to be(error)
    end

    it "sets MCP-specific reason when origin is :mcp" do
      mcp_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "mcp_tool"
        description "d"
        requires_approval true
        def tool_origin
          :mcp
        end

        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "mcp_tool", {})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: mcp_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      outcome = inv.send(:evaluate_authorization)
      expect(outcome.reason).to include("MCP")
    end

    it "raises ConfigurationError when policy returns invalid decision" do
      bad_policy = ->(_req) { :invalid }
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: tool,
        tool_call: tool_call, config: {}, approval_policy: bad_policy
      )
      inv.validate!
      expect { inv.send(:evaluate_authorization) }.to raise_error(Phronomy::ConfigurationError)
    end
  end

  describe "evaluate_facts" do
    it "returns empty hash when tool has no approval_facts" do
      plain_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "plain"
        description "d"
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "plain", {})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: plain_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      facts = inv.send(:evaluate_facts)
      expect(facts).to eq({})
    end

    it "raises ConfigurationError when approval_facts returns non-Hash" do
      bad_facts_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "bad_facts"
        description "d"
        approval_facts { |_args, _ctx| "not_a_hash" }
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "bad_facts", {})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: bad_facts_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      expect { inv.send(:evaluate_facts) }.to raise_error(Phronomy::ConfigurationError)
    end
  end

  describe "evaluate_default_decision" do
    it "returns :require_approval when requires_approval is true" do
      req_true = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "req"
        description "d"
        requires_approval true
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "req", {})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: req_true,
        tool_call: stub, config: {}
      )
      inv.validate!
      request = inv.send(:build_request, facts: {}, default_decision: nil)
      expect(inv.send(:evaluate_default_decision, request)).to eq(:require_approval)
    end

    it "returns :allow when requires_approval is false" do
      req_false = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "noq"
        description "d"
        requires_approval false
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "noq", {})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: req_false,
        tool_call: stub, config: {}
      )
      inv.validate!
      request = inv.send(:build_request, facts: {}, default_decision: nil)
      expect(inv.send(:evaluate_default_decision, request)).to eq(:allow)
    end

    it "raises ConfigurationError when callable returns invalid value" do
      bad_callable = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "bad_callable"
        description "d"
        requires_approval { |_req| "invalid" }
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "bad_callable", {})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: bad_callable,
        tool_call: stub, config: {}
      )
      inv.validate!
      request = inv.send(:build_request, facts: {}, default_decision: nil)
      expect { inv.send(:evaluate_default_decision, request) }.to raise_error(Phronomy::ConfigurationError)
    end
  end

  describe "apply_authorization_outcome" do
    it "sets :cancelled status on cancelled outcome" do
      outcome = Phronomy::Agent::ToolInvocation::AuthorizationOutcome.new(
        error: Phronomy::CancellationError.new("x"), cancelled: true
      )
      invocation.send(:apply_authorization_outcome, outcome)
      expect(invocation.cancelled?).to be true
    end

    it "sets :failed status on error outcome" do
      outcome = Phronomy::Agent::ToolInvocation::AuthorizationOutcome.new(
        error: RuntimeError.new("boom"), cancelled: false
      )
      invocation.send(:apply_authorization_outcome, outcome)
      expect(invocation.failed?).to be true
    end

    it "sets :rejected status when decision is :reject" do
      outcome = Phronomy::Agent::ToolInvocation::AuthorizationOutcome.new(
        decision: :reject, facts: {}, reason: nil
      )
      invocation.send(:apply_authorization_outcome, outcome)
      expect(invocation.rejected?).to be true
    end
  end

  describe "apply_execution_outcome" do
    it "sets :cancelled status on cancelled execution" do
      outcome = Phronomy::Agent::ToolInvocation::ExecutionOutcome.new(
        error: Phronomy::CancellationError.new("x"), cancelled: true
      )
      invocation.send(:apply_execution_outcome, outcome)
      expect(invocation.cancelled?).to be true
    end

    it "sets :failed status on error execution" do
      outcome = Phronomy::Agent::ToolInvocation::ExecutionOutcome.new(
        error: RuntimeError.new("boom")
      )
      invocation.send(:apply_execution_outcome, outcome)
      expect(invocation.failed?).to be true
    end

    it "sets :completed status on success" do
      outcome = Phronomy::Agent::ToolInvocation::ExecutionOutcome.new(result: "done")
      invocation.send(:apply_execution_outcome, outcome)
      expect(invocation.execution_completed?).to be true
      expect(invocation.result).to eq("done")
    end
  end

  describe "status predicates" do
    it "returns preflight_settled? true after authorization" do
      invocation.validate!
      invocation.send(:apply_authorization_outcome,
        Phronomy::Agent::ToolInvocation::AuthorizationOutcome.new(
          decision: :allow, facts: {}, reason: nil
        ))
      expect(invocation.preflight_settled?).to be true
    end

    it "validation_completed? true when schema error returns result" do
      err_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "ecomplete"
        description "d"
        on_schema_error :return_error
        param :count, type: :integer, desc: "c"
        def execute(count:)
          count.to_s
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "ecomplete", {"count" => "bad"})
      inv = described_class.new(
        parent_agent_invocation_id: "a", agent: agent, tool: err_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      expect(inv.validation_completed?).to be true
    end
  end
end
