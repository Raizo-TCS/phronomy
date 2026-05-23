# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Security-focused specs (Issue #214)
#
# Covers two areas:
#   1. trace_pii redaction — both input AND output sent to tracer are
#      [REDACTED] when trace_pii is false; the caller still gets the real result.
#   2. Approval-required tool gate — execution is blocked and the caller never
#      invokes #execute when the approval handler returns falsy.
# ---------------------------------------------------------------------------
RSpec.describe "Security specs (Issue #214)" do
  # ---------------------------------------------------------------------------
  # Helper: a tracer that captures both input and output for each span.
  # ---------------------------------------------------------------------------
  let(:recorded_spans) { [] }

  let(:recording_tracer) do
    spans = recorded_spans
    Class.new(Phronomy::Tracing::Base) do
      define_method(:start_span) do |name, input: nil, **|
        span = {name: name, input: input, output: nil}
        spans << span
        span
      end
      define_method(:finish_span) do |span, output: nil, **|
        span[:output] = output
      end
    end.new
  end

  # ---------------------------------------------------------------------------
  # A minimal Runnable that wraps its block result in a trace span.
  # Returns the value as-is (simulates a chain step).
  # ---------------------------------------------------------------------------
  let(:traceable_step) do
    Class.new do
      include Phronomy::Runnable

      def invoke(input, config: {})
        trace("step", input: input) { [input.upcase, nil] }
      end
    end.new
  end

  after { Phronomy.reset_configuration! }

  # -------------------------------------------------------------------------
  # Section 1: trace_pii redaction
  # -------------------------------------------------------------------------
  describe "trace_pii redaction" do
    before do
      Phronomy.configure { |c| c.tracer = recording_tracer }
    end

    context "when trace_pii is false (default)" do
      before { Phronomy.configure { |c| c.trace_pii = false } }

      it "sends [REDACTED] as input to the tracer" do
        traceable_step.invoke("top secret input")
        expect(recorded_spans.first[:input]).to eq("[REDACTED]")
      end

      it "sends [REDACTED] as output to the tracer" do
        traceable_step.invoke("sensitive data")
        expect(recorded_spans.first[:output]).to eq("[REDACTED]")
      end

      it "still returns the real (unredacted) result to the caller" do
        result = traceable_step.invoke("hello")
        expect(result).to eq("HELLO")
      end
    end

    context "when trace_pii is true" do
      before { Phronomy.configure { |c| c.trace_pii = true } }

      it "passes the real input to the tracer" do
        traceable_step.invoke("visible input")
        expect(recorded_spans.first[:input]).to eq("visible input")
      end

      it "passes the real output to the tracer" do
        traceable_step.invoke("hello")
        expect(recorded_spans.first[:output]).to eq("HELLO")
      end
    end
  end

  # -------------------------------------------------------------------------
  # Section 2: Approval-required tool gate
  # -------------------------------------------------------------------------
  describe "approval-required tool gate" do
    # A sensitive tool that records every execute call in `audit_log`.
    let(:audit_log) { [] }

    let(:sensitive_tool_class) do
      log = audit_log
      Class.new(Phronomy::Tool::Base) do
        tool_name "sensitive_op"
        description "Performs a sensitive operation"
        requires_approval true
        param :target, type: :string, desc: "Target resource"

        define_method(:execute) do |target:|
          log << "EXECUTED:#{target}"
          "result for #{target}"
        end
      end
    end

    def build_agent
      Class.new(Phronomy::Agent::Base) { model "test-model" }.new
    end

    context "when handler returns false" do
      it "does not invoke #execute" do
        agent = build_agent
        agent.on_approval_required { false }

        wrapped = agent.send(:prepare_tool_class, sensitive_tool_class)
        wrapped.new.call({"target" => "production-db"})

        expect(audit_log).to be_empty
      end

      it "returns a denial message string" do
        agent = build_agent
        agent.on_approval_required { false }

        wrapped = agent.send(:prepare_tool_class, sensitive_tool_class)
        output = wrapped.new.call({"target" => "anything"})

        expect(output).to eq("Tool execution denied.")
      end
    end

    context "when handler returns nil" do
      it "does not invoke #execute" do
        agent = build_agent
        agent.on_approval_required { nil }

        wrapped = agent.send(:prepare_tool_class, sensitive_tool_class)
        wrapped.new.call({"target" => "secret-endpoint"})

        expect(audit_log).to be_empty
      end
    end

    context "when handler returns truthy" do
      it "invokes #execute and returns its result" do
        agent = build_agent
        agent.on_approval_required { true }

        wrapped = agent.send(:prepare_tool_class, sensitive_tool_class)
        output = wrapped.new.call({"target" => "safe-resource"})

        expect(audit_log).to eq(["EXECUTED:safe-resource"])
        expect(output).to eq("result for safe-resource")
      end
    end

    context "approval audit trail" do
      it "passes tool name and arguments to the handler for audit purposes" do
        received_name = nil
        received_args = nil

        agent = build_agent
        agent.on_approval_required do |name, args|
          received_name = name
          received_args = args
          true
        end

        wrapped = agent.send(:prepare_tool_class, sensitive_tool_class)
        wrapped.new.call({"target" => "audit-target"})

        expect(received_name).to eq("sensitive_op")
        expect(received_args).to include("target" => "audit-target")
      end
    end

    context "when no handler is registered (backward compatibility)" do
      it "executes the tool without approval" do
        agent = build_agent
        # Deliberately no on_approval_required call
        wrapped = agent.send(:prepare_tool_class, sensitive_tool_class)
        output = wrapped.new.call({"target" => "legacy-target"})

        expect(audit_log).to eq(["EXECUTED:legacy-target"])
        expect(output).to eq("result for legacy-target")
      end
    end
  end
end
