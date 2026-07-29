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
      Class.new(Phronomy::Filter::Base) do
        def call(output, **_ctx)
          block!("Guardrail always rejects: #{output}")
          output
        end
      end.new
    end

    let(:exploding_guardrail) do
      Class.new(Phronomy::Filter::Base) do
        def call(_output, **_ctx)
          raise "guardrail itself exploded"
        end
      end.new
    end

    it "raises FilterBlockError when output guardrail rejects" do
      expect { always_reject_guardrail.call("some output") }.to raise_error(Phronomy::FilterBlockError)
    end

    it "includes the rejection reason in FilterBlockError message" do
      expect { always_reject_guardrail.call("test") }
        .to raise_error(Phronomy::FilterBlockError, /always rejects/)
    end

    it "propagates unexpected exceptions from guardrail#check unchanged" do
      expect { exploding_guardrail.call("test") }
        .to raise_error(RuntimeError, "guardrail itself exploded")
    end

    it "passes the guardrail for valid output" do
      passing_guardrail = Class.new(Phronomy::Filter::Base) do
        def call(value, **_ctx) = value
      end.new

      expect { passing_guardrail.call("fine output") }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  # 2. Tool execute fault isolation
  # -------------------------------------------------------------------------
  describe "Tool execute fault isolation" do
    let(:raising_tool) do
      Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "A tool that always raises"

        def execute
          raise ArgumentError, "bad tool argument"
        end
      end.new
    end

    let(:suppressed_tool) do
      Class.new(Phronomy::Agent::Context::Capability::Base) do
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
      Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "A tool requiring approval"
        requires_approval true

        def execute
          "executed"
        end
      end
    end

    it "prepare_tool_class no longer wraps with an approval callback (authorization is now ToolInvocation's responsibility)" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test-model"
      end
      agent = agent_class.new
      # New API: tool_approval_policy returns :reject to deny execution
      agent.tool_approval_policy { :reject }

      # prepare_tool_class only handles alias and result filters; no inline denial
      wrapped = agent.send(:prepare_tool_class, approval_required_tool_class)
      # The Tool#call itself runs; authorization gate is in ToolInvocation FSM
      result = wrapped.new.call({})
      expect(result).to eq("executed")
    end

    it "prepare_tool_class with tool_approval_policy :allow still executes the tool" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        model "test-model"
      end
      agent = agent_class.new
      agent.tool_approval_policy { :allow }

      wrapped = agent.send(:prepare_tool_class, approval_required_tool_class)
      result = wrapped.new.call({})
      expect(result).to eq("executed")
    end
  end

  # -------------------------------------------------------------------------
  # 4. Tracer backend raises on start_span
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
    it "raises RuntimeShutdownError when the EventLoop state is :stopping" do
      runtime = Phronomy::Runtime.new
      loop = runtime.event_loop

      # Transition to :stopping to simulate shutdown in progress.
      loop.instance_variable_get(:@lifecycle_mutex).synchronize do
        loop.instance_variable_set(:@state, :stopping)
      end

      fsm_double = instance_double(Phronomy::FSMSession,
        id: "test-session-#{rand(100_000)}",
        start: nil)

      expect { loop.register(fsm_double) }.to raise_error(Phronomy::RuntimeShutdownError)
    ensure
      begin
        runtime&.shutdown(timeout: 1)
      rescue
        nil
      end
    end
  end
end
