# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Extended fault injection tests (Issue #230)
#
# Verifies additional failure scenarios:
#   1. Output guardrail fault isolation
#   2. Tool execute fault isolation
#   3. Tool approval handler denial
#   4. Knowledge source (RAG) loader raises
#   5. Tracer backend raises
#   6. EventLoop shutdown rejects new sessions
# ---------------------------------------------------------------------------
RSpec.describe "Fault injection (Issue #230 — extended)" do
  # -------------------------------------------------------------------------
  # 1. Output guardrail fault isolation
  # -------------------------------------------------------------------------
  describe "Output guardrail fault isolation" do
    let(:always_reject_guardrail) do
      Class.new(Phronomy::Guardrail::OutputGuardrail) do
        def check(output)
          fail!("Guardrail always rejects: #{output}")
        end
      end.new
    end

    let(:exploding_guardrail) do
      Class.new(Phronomy::Guardrail::OutputGuardrail) do
        def check(_output)
          raise "guardrail itself exploded"
        end
      end.new
    end

    it "raises GuardrailError when output guardrail rejects" do
      expect { always_reject_guardrail.run!("some output") }.to raise_error(Phronomy::GuardrailError)
    end

    it "includes the rejection reason in GuardrailError message" do
      expect { always_reject_guardrail.run!("test") }
        .to raise_error(Phronomy::GuardrailError, /always rejects/)
    end

    it "propagates unexpected exceptions from guardrail#check unchanged" do
      expect { exploding_guardrail.run!("test") }
        .to raise_error(RuntimeError, "guardrail itself exploded")
    end

    it "passes the guardrail for valid output" do
      passing_guardrail = Class.new(Phronomy::Guardrail::OutputGuardrail) do
        def check(_output)
        end
      end.new

      expect { passing_guardrail.run!("fine output") }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # 2. Tool execute fault isolation
  # -------------------------------------------------------------------------
  describe "Tool execute fault isolation" do
    let(:raising_tool) do
      Class.new(Phronomy::Tool::Base) do
        description "A tool that always raises"

        def execute
          raise ArgumentError, "bad tool argument"
        end
      end.new
    end

    let(:suppressed_tool) do
      Class.new(Phronomy::Tool::Base) do
        description "A tool that suppresses errors"
        on_error :suppress

        def execute
          raise "internal tool error"
        end
      end.new
    end

    it "wraps execute exception as Phronomy::ToolError (on_error: :raise)" do
      expect { raising_tool.call({}) }.to raise_error(Phronomy::ToolError)
    end

    it "does not raise when on_error: :suppress" do
      expect { suppressed_tool.call({}) }.not_to raise_error
    end

    it "returns a non-nil String when on_error: :suppress" do
      result = suppressed_tool.call({})
      expect(result).to be_a(String)
    end

    it "Phronomy::ToolError message includes the original error message" do
      expect { raising_tool.call({}) }
        .to raise_error(Phronomy::ToolError, /bad tool argument/)
    end
  end

  # -------------------------------------------------------------------------
  # 3. Tool approval handler denial
  # -------------------------------------------------------------------------
  describe "Tool approval handler denial" do
    let(:approval_required_tool_class) do
      Class.new(Phronomy::Tool::Base) do
        description "A tool requiring approval"
        requires_approval true

        def execute
          "executed"
        end
      end
    end

    it "returns a denial String when the approval handler returns false" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test-model"
      end
      agent = agent_class.new
      agent.on_approval_required { |_name, _args| false }

      wrapped = agent.send(:prepare_tool_class, approval_required_tool_class)
      result = wrapped.new.call({})
      expect(result).to eq("Tool execution denied.")
    end

    it "executes normally when the approval handler returns true" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test-model"
      end
      agent = agent_class.new
      agent.on_approval_required { |_name, _args| true }

      wrapped = agent.send(:prepare_tool_class, approval_required_tool_class)
      result = wrapped.new.call({})
      expect(result).to eq("executed")
    end
  end

  # -------------------------------------------------------------------------
  # 4. Knowledge source (RAG) loader raises
  # -------------------------------------------------------------------------
  describe "Knowledge source loader raises" do
    let(:exploding_knowledge_source) do
      Class.new(Phronomy::KnowledgeSource::Base) do
        def fetch(query:)
          raise Phronomy::Error, "knowledge source unavailable"
        end
      end.new
    end

    it "propagates the exception from build_context when knowledge source raises" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test-model"
      end
      agent = agent_class.new

      expect {
        agent.send(:build_context, "query",
          config: {knowledge_sources: [exploding_knowledge_source]})
      }.to raise_error(Phronomy::Error, "knowledge source unavailable")
    end
  end

  # -------------------------------------------------------------------------
  # 5. Tracer backend raises on start_span
  # -------------------------------------------------------------------------
  describe "Tracer backend raises on start_span" do
    let(:exploding_tracer) do
      Class.new(Phronomy::Tracing::Base) do
        def start_span(name, **_attrs)
          raise "tracer connection failed"
        end

        def finish_span(span, **_opts)
        end
      end.new
    end

    it "propagates the tracer error to the caller (current documented behavior)" do
      # NOTE: The Issue #230 desired behavior is that tracer errors are
      # absorbed silently so that the agent continues. The current implementation
      # of Phronomy::Tracing::Base#trace does NOT rescue start_span errors.
      # This test documents the CURRENT behavior. A separate issue should be
      # filed if transparent tracer fault isolation is required.
      expect {
        exploding_tracer.trace("test_span", input: "hello") { ["result", nil] }
      }.to raise_error(RuntimeError, "tracer connection failed")
    end

    it "NullTracer never raises on start_span" do
      tracer = Phronomy::Tracing::NullTracer.new
      expect { tracer.start_span("test", input: "x") }.not_to raise_error
    end

    it "NullTracer never raises on finish_span" do
      tracer = Phronomy::Tracing::NullTracer.new
      span = tracer.start_span("test")
      expect { tracer.finish_span(span, output: "result") }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # 6. EventLoop shutdown rejects new sessions with CancellationError
  # -------------------------------------------------------------------------
  describe "EventLoop shutdown rejects new sessions" do
    it "pushes a CancellationError into the completion queue when shutting down" do
      loop = Phronomy::EventLoop.new
      loop.start

      # Cancel the shutdown token directly to simulate a shutdown in progress
      loop.instance_variable_get(:@shutdown_token).cancel!

      # Build a minimal FSMSession double that can be inspected
      fsm_double = instance_double(Phronomy::FSMSession,
        id: "test-session-#{rand(100_000)}",
        start: nil)

      cq = loop.register(fsm_double)

      # The loop should push a CancellationError without calling fsm.start
      result = cq.pop
      expect(result).to be_a(Phronomy::CancellationError)
      expect(result.message).to match(/shutting down/i)
    ensure
      loop&.stop
    end
  end
end
