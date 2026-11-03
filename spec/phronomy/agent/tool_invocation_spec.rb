# frozen_string_literal: true

require "spec_helper"
require "delegate"

RSpec.describe Phronomy::Agent::ToolInvocation do
  describe ".semantic_id" do
    it "preserves the stored identity format without constructing an invocation" do
      expect(described_class).not_to receive(:new)
      identity = described_class.semantic_id(execution_id: "execution-1",
        llm_call_id: "llm-1", tool_call_id: "call-1", tool_name: "lookup")
      expect(identity).to eq("tool_invocation-815a11f936d7517dab00e0e18274004437ceecee442e136c991f0f213aa8b705")
      expect(identity).to be_frozen
      expect(described_class.semantic_id(execution_id: "execution-1",
        llm_call_id: "llm-2", tool_call_id: "call-1", tool_name: "lookup")).not_to eq(identity)
    end
  end

  ToolCall = Struct.new(:id, :name, :arguments)

  let(:tool_class) do
    Class.new(Phronomy::Tool::Base) do
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

  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "tool-invocation-spec-agent", version: 1

      def initialize(agent_id:)
        @agent_id = agent_id.to_s.freeze
      end
    end
  end

  let(:agent) do
    agent_class.new(agent_id: "tool-invocation-spec-agent-instance")
  end
  let(:tool_call) do
    ToolCall.new(
      id: "call-1",
      name: "send_message",
      arguments: {"recipients" => Array.new(11, "a@example.net"), "body" => "secret"}
    )
  end

  subject(:invocation) do
    described_class.new(
      execution_id: "execution-1",
      agent: agent,
      tool: tool,
      tool_call: tool_call,
      config: {},
      approval_context: {environment: :production}
    )
  end

  it "validates arguments before evaluating approval facts" do
    invocation.validate!
    outcome = Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, invocation.send(:authorization_command))

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
      execution_id: "execution-1",
      agent: agent,
      tool: tool,
      tool_call: tool_call,
      config: {},
      approval_policy: policy,
      approval_context: {environment: :production}
    )

    invocation.validate!
    outcome = Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, invocation.send(:authorization_command))

    expect(outcome.decision).to eq(:reject)
  end

  it "redacts sensitive arguments and String-valued facts from UI output" do
    invocation.validate!
    invocation.send(:apply_authorization_outcome, Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, invocation.send(:authorization_command)))

    expect(invocation.display_arguments[:body]).to eq("[REDACTED]")
    expect(invocation.display_facts[:recipient_count]).to eq(11)
    expect(invocation.display_facts[:external_domain]).to eq("[REDACTED]")
  end

  describe "#approval_display" do
    it "preserves a Base Tool's existing private redaction override" do
      tool_class.class_eval do
        private

        def redacted_args(args)
          {recipient_count: args.fetch("recipients").size}
        end
      end

      expect(invocation.display_arguments).to eq(recipient_count: 11)
      expect(invocation.raw_arguments.fetch("body")).to eq("secret")
    end

    it "builds an approval item from one public Tool projection and snapshots both fields" do
      projection = {arguments: {audience: ["operator"]}, facts: {zone: ["public"]}}
      allow(tool).to receive(:approval_display).and_return(projection)
      invocation.validate!
      invocation.mark_awaiting_approval!
      batch = Struct.new(:execution_id, :tool_invocations).new("execution-1", [invocation])

      item = Phronomy::Agent::ToolApprovalRequest.build(batch).items.first
      expect(tool).to have_received(:approval_display).with(arguments: invocation.arguments, facts: {}).once
      projection.fetch(:arguments).fetch(:audience).clear
      projection.fetch(:facts).fetch(:zone).clear
      expect(item.arguments).to eq(audience: ["operator"])
      expect(item.facts).to eq(zone: ["public"])
      expect(item.arguments.fetch(:audience)).to be_frozen
      expect(invocation.arguments.fetch(:body)).to eq("secret")
    end

    it "rejects malformed projections without substituting raw policy data" do
      [nil, {}, {arguments: [], facts: {}}, {arguments: {}, facts: "secret"}].each do |invalid|
        allow(tool).to receive(:approval_display).and_return(invalid)
        expect { invocation.approval_display }.to raise_error(Phronomy::ConfigurationError, /approval_display/)
      end
    end

    context "with a Tool that supplies no public approval display operation" do
      let(:tool) do
        Class.new do
          private

          def redacted_args(_args)
            raise "private Tool method called"
          end
        end.new
      end

      it "omits arguments and derived facts from the approval request while retaining policy data" do
        facts = {"secret" => {count: 1234, external: false}}
        invocation.send(:apply_authorization_outcome, described_class::AuthorizationOutcome.new(
          decision: :require_approval, facts: facts
        ))
        batch = Struct.new(:execution_id, :tool_invocations).new("execution-1", [invocation])
        request = Phronomy::Agent::ToolApprovalRequest.build(batch)

        expect(request.to_h.fetch(:items).first).to include(arguments: {}, facts: {})
        expect(invocation.facts).to eq(facts)
        expect(invocation.raw_arguments.fetch("body")).to eq("secret")
      end
    end
  end

  describe "#display_facts" do
    it "omits the entire facts Hash if it equals a sensitive argument" do
      tool_class.redact_params :payload
      [{}, {token: "secret"}].each do |sensitive|
        expect(tool.approval_display(arguments: {payload: sensitive}, facts: sensitive)).to eq(
          arguments: {payload: "[REDACTED]"}, facts: {}
        )
      end
    end

    it "masks declared sensitive values including false and omits matching Hash keys at any depth" do
      tool_class.param :flag, type: :boolean, desc: "Flag"
      tool_class.redact_params :flag
      tool_call.arguments["flag"] = false
      tool_class.approval_facts do |args, _context|
        group = {
          args.fetch(:body) => 1,
          args.fetch(:body).to_sym => 2,
          "[REDACTED]" => 3,
          :recipients => args.fetch(:recipients).size
        }
        {flags: [args.fetch(:flag)], groups: [group]}
      end
      tool_class.requires_approval true
      invocation.validate!
      outcome = described_class.send(:evaluate_authorization_command, invocation.send(:authorization_command))
      invocation.send(:apply_authorization_outcome, outcome)

      expect(invocation.display_facts).to eq(flags: ["[REDACTED]"], groups: [{"[REDACTED]" => 3, :recipients => 11}])
      expect(invocation.facts.fetch(:groups).first).to include("secret" => 1, :secret => 2)
      expect(invocation.arguments.fetch(:flag)).to be(false)
    end

    context "when a wrapper delegates the Tool display operation" do
      let(:tool) do
        Class.new(SimpleDelegator) do
          def self.approval_facts
            ->(args, _context) { {copied_pin: args.fetch(:pin)} }
          end
        end.new(tool_class.new)
      end

      it "uses the wrapped Tool's sensitive declarations for both arguments and derived facts" do
        tool_class.param :pin, type: :integer, desc: "PIN"
        tool_class.redact_params :pin
        tool_class.requires_approval true
        tool_call.arguments["pin"] = 1234
        invocation.validate!
        outcome = described_class.send(:evaluate_authorization_command, invocation.send(:authorization_command))
        invocation.send(:apply_authorization_outcome, outcome)

        expect(invocation.display_arguments).to include(pin: "[REDACTED]")
        expect(invocation.display_facts).to eq(copied_pin: "[REDACTED]")
        expect(invocation.facts).to eq(copied_pin: 1234)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Branch coverage: constructor duck-typing, validate!, dispatchable?,
  # evaluate_authorization error paths, evaluate_facts, evaluate_default_decision
  # ---------------------------------------------------------------------------

  describe "constructor duck-typing" do
    it "accepts a tool_call without :id method" do
      stub = Struct.new(:name, :arguments).new("send_message", {"recipients" => [], "body" => "hi"})
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: tool,
        tool_call: stub, config: {}
      )
      expect(inv.instance_variable_get(:@tool_call_id)).to be_nil
    end

    it "accepts a tool_call without :arguments method" do
      stub = Struct.new(:id, :name).new("call-2", "send_message")
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: tool,
        tool_call: stub, config: {}
      )
      expect(inv.instance_variable_get(:@raw_arguments)).to eq({})
    end

    it "uses :local origin when tool does not respond to tool_origin" do
      basic_tool = Class.new(Phronomy::Tool::Base) do
        tool_name "basic"
        description "basic"
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "basic", {})
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: basic_tool,
        tool_call: stub, config: {}
      )
      expect(inv.instance_variable_get(:@origin)).to eq(:local)
    end

    it "defaults approval_context to empty hash when nil" do
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: tool,
        tool_call: tool_call, config: {}, approval_context: nil
      )
      expect(inv.instance_variable_get(:@approval_context)).to eq({})
    end
  end

  describe "#validate!" do
    it "returns :completed status when schema validation fails with return_error policy" do
      err_tool = Class.new(Phronomy::Tool::Base) do
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
        execution_id: "execution-1",
        agent: agent, tool: err_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      expect(inv.instance_variable_get(:@status)).to eq(:completed)
    end

    it "returns :failed status when schema validation fails with :raise policy" do
      raise_tool = Class.new(Phronomy::Tool::Base) do
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
        execution_id: "execution-1",
        agent: agent, tool: raise_tool,
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
      expect(invocation).not_to receive(:validate_arguments)
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
      outcome = Phronomy::Agent::ToolInvocation.send(:authorization_failure_result, invocation.id, error)
      expect(outcome.decision).to eq(:require_approval)
    end

    it "returns cancelled outcome on CancellationError" do
      error = Phronomy::CancellationError.new("cancelled")
      outcome = Phronomy::Agent::ToolInvocation.send(:authorization_failure_result, invocation.id, error)
      expect(outcome.cancelled).to be true
    end

    it "returns error outcome on unexpected error" do
      error = RuntimeError.new("boom")
      outcome = Phronomy::Agent::ToolInvocation.send(:authorization_failure_result, invocation.id, error)
      expect(outcome.error).to be(error)
    end

    it "sets MCP-specific reason when origin is :mcp" do
      mcp_tool = Class.new(Phronomy::Tool::Base) do
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
        execution_id: "execution-1",
        agent: agent, tool: mcp_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      outcome = Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, inv.send(:authorization_command))
      expect(outcome.reason).to include("MCP")
    end

    it "raises ConfigurationError when policy returns invalid decision" do
      bad_policy = ->(_req) { :invalid }
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: tool,
        tool_call: tool_call, config: {}, approval_policy: bad_policy
      )
      inv.validate!
      expect { Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, inv.send(:authorization_command)) }.to raise_error(Phronomy::ConfigurationError)
    end
  end

  describe "evaluate_facts" do
    it "returns empty hash when tool has no approval_facts" do
      plain_tool = Class.new(Phronomy::Tool::Base) do
        tool_name "plain"
        description "d"
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "plain", {})
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: plain_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      facts = Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, inv.send(:authorization_command)).facts
      expect(facts).to eq({})
    end

    it "raises ConfigurationError when approval_facts returns non-Hash" do
      bad_facts_tool = Class.new(Phronomy::Tool::Base) do
        tool_name "bad_facts"
        description "d"
        approval_facts { |_args, _ctx| "not_a_hash" }
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "bad_facts", {})
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: bad_facts_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      expect { Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, inv.send(:authorization_command)).facts }.to raise_error(Phronomy::ConfigurationError)
    end
  end

  describe "evaluate_default_decision" do
    it "returns :require_approval when requires_approval is true" do
      req_true = Class.new(Phronomy::Tool::Base) do
        tool_name "req"
        description "d"
        requires_approval true
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "req", {})
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: req_true,
        tool_call: stub, config: {}
      )
      inv.validate!

      expect(Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, inv.send(:authorization_command)).decision).to eq(:require_approval)
    end

    it "returns :allow when requires_approval is false" do
      req_false = Class.new(Phronomy::Tool::Base) do
        tool_name "noq"
        description "d"
        requires_approval false
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "noq", {})
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: req_false,
        tool_call: stub, config: {}
      )
      inv.validate!

      expect(Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, inv.send(:authorization_command)).decision).to eq(:allow)
    end

    it "raises ConfigurationError when callable returns invalid value" do
      bad_callable = Class.new(Phronomy::Tool::Base) do
        tool_name "bad_callable"
        description "d"
        requires_approval { |_req| "invalid" }
        def execute
          "ok"
        end
      end.new
      stub = Struct.new(:id, :name, :arguments).new("c", "bad_callable", {})
      inv = described_class.new(
        execution_id: "execution-1",
        agent: agent, tool: bad_callable,
        tool_call: stub, config: {}
      )
      inv.validate!

      expect { Phronomy::Agent::ToolInvocation.send(:evaluate_authorization_command, inv.send(:authorization_command)).decision }.to raise_error(Phronomy::ConfigurationError)
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
      err_tool = Class.new(Phronomy::Tool::Base) do
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
        execution_id: "execution-1",
        agent: agent, tool: err_tool,
        tool_call: stub, config: {}
      )
      inv.validate!
      expect(inv.validation_completed?).to be true
    end
  end
end
