# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

# Public behavior checks also run unchanged against the unit20 implementation.
RSpec.describe "Tool and Tracing configuration behavior" do
  let(:tool_class) do
    Class.new(Phronomy::Tool::Base) do
      tool_name "configured-result"
      param :value, type: :string
      def execute(value:) = value
    end
  end
  let(:tracer_class) do
    Class.new(Phronomy::Tracing::Base) do
      attr_reader :spans

      def initialize
        @spans = []
      end

      def start_span(name, **attributes)
        {name: name, **attributes}.tap { |span| @spans << span }
      end

      def finish_span(span, **attributes)
        raise "foreign span" unless @spans.any? { |owned| owned.equal?(span) }
        span.merge!(attributes)
      end
    end
  end

  before { Phronomy.configuration.logger = Logger.new(StringIO.new) }

  def prepare_context(assembly)
    input = Phronomy::Context::ContextPolicyInput.new(
      agent_id: "settings-agent", execution_id: "settings-execution",
      call_sequence: 1, call_mode: :ask, token_budget: nil, previous_manifest: nil
    )
    assembly.prepare(input: input, policy: ->(_) { Phronomy::Context::ContextPlan.new }, adapter_identity: {})
  end

  it "reads a changed global result limit on each call to an existing Tool" do
    tool = tool_class.new
    Phronomy.configuration.tool_result_max_size = 3
    expect(tool.call({value: "abcdef"})).to eq("abc...[truncated]")
    Phronomy.configuration.tool_result_max_size = 5
    expect(tool.call({value: "abcdef"})).to eq("abcde...[truncated]")
    Phronomy.configuration.tool_result_max_size = nil
    expect(tool.call({value: "abcdef"})).to eq("abcdef")
  end

  it "keeps class limits ahead of the global default, including zero" do
    Phronomy.configuration.tool_result_max_size = 1
    tool_class.max_result_size 4
    expect(tool_class.new.call({value: "abcdef"})).to eq("abcd...[truncated]")
    tool_class.max_result_size 0
    expect(tool_class.new.call({value: "abcdef"})).to eq("...[truncated]")
  end

  it "reads the result limit after synchronous execution, not before it" do
    Phronomy.configuration.tool_result_max_size = 1
    tool_class.define_method(:execute) do |value:|
      Phronomy.configuration.tool_result_max_size = 4
      value
    end
    expect(tool_class.new.call({value: "abcdef"})).to eq("abcd...[truncated]")
  end

  it "reads the result limit after cooperative execution without changing filter order or repetition" do
    tool_class.execution_mode :cooperative
    tool_class.define_method(:execute) do |value:|
      Phronomy.configuration.tool_result_max_size = 2
      value
    end
    seen = []
    transform = ->(value, *) {
      seen << value
      "[#{value}]"
    }
    decorated = Phronomy::Tool::Operation.with_result_transform(tool_class, &transform)
    decorated = Phronomy::Tool::Operation.with_result_transform(decorated, &transform)
    expect(decorated.new.call_async({value: "abcdef"}).wait_result).to eq("[[ab...[truncated]]]")
    expect(seen).to eq(["ab...[truncated]", "[ab...[truncated]]"])
  end

  it "resolves a replacement configuration after offloaded execution finishes" do
    started = Queue.new
    release = Queue.new
    tool_class.define_method(:execute) do |value:|
      started << true
      release.pop
      value
    end
    Phronomy.configuration.tool_result_max_size = 1
    result = tool_class.new.call_async({value: "abcdef"})
    Timeout.timeout(3) { started.pop }
    Phronomy.reset_configuration!
    Phronomy.configuration.tool_result_max_size = 4
    release << true
    expect(result.wait_result(timeout: 3)).to eq("abcd...[truncated]")
  ensure
    release << true if release
  end

  it "reads the limit at asynchronous operation completion and retains physical completion" do
    source = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    tool_class.define_method(:call_async) do |args, **|
      call_async_operation(args, cancellation_token: nil, operation_name: "settings-operation") { source }
    end
    Phronomy.configuration.tool_result_max_size = 1
    result = tool_class.new.call_async({value: "unused"})
    Phronomy.configuration.tool_result_max_size = 3
    source.complete("abcdef")
    expect(result.wait_result).to eq("abc...[truncated]")
    expect(result.physical_complete?).to be(false)
    source.mark_physical_complete!
    expect(result.physical_complete?).to be(true)
  end

  it "retains original result identity when no limit is configured" do
    value = Object.new
    tool_class.define_method(:execute) { |**| value }
    Phronomy.configuration.tool_result_max_size = nil
    expect(tool_class.new.call({value: "ignored"})).to be(value)
  end

  it "restores nested scopes after failure while preserving tracer identity and explicit nil" do
    original = tracer_class.new
    outer_tracer = tracer_class.new
    Phronomy.configure do |config|
      config.tracer = original
      config.tool_result_max_size = 2
    end
    expect {
      Phronomy.with_configuration do |outer|
        outer.tracer = outer_tracer
        outer.trace_pii = true
        outer.tool_result_max_size = 4
        Phronomy.with_configuration do |inner|
          inner.tracer = nil
          inner.trace_pii = nil
          inner.tool_result_max_size = nil
          expect(inner.tracer).to be_nil
          expect(inner.trace_pii).to be_nil
          expect(tool_class.new.call({value: "abcdef"})).to eq("abcdef")
        end
        expect(Phronomy.configuration.tracer).to be(outer_tracer)
        expect(Phronomy.configuration.trace_pii).to be(true)
        expect(tool_class.new.call({value: "abcdef"})).to eq("abcd...[truncated]")
        raise "scope failed"
      end
    }.to raise_error("scope failed")
    expect(Phronomy.configuration.tracer).to be(original)
    expect(Phronomy.configuration.trace_pii).to be(false)
    expect(tool_class.new.call({value: "abcdef"})).to eq("ab...[truncated]")
  end

  it "copies option values without cloning injected tracer instances" do
    original = Phronomy.configuration
    original.tracer = tracer_class.new
    copy = original.dup
    expect(copy.tracer).to be(original.tracer)
    copy.tracer = nil
    copy.trace_pii = true
    copy.tool_result_max_size = 2
    expect(original.tracer).to be_a(tracer_class)
    expect(original.trace_pii).to be(false)
    expect(original.tool_result_max_size).to be_nil
  end

  it "restores fresh defaults after reset for subsequent Tool and Tracing calls" do
    old_tracer = tracer_class.new
    Phronomy.configure do |config|
      config.tracer = old_tracer
      config.trace_pii = true
      config.tool_result_max_size = 1
    end
    Phronomy.reset_configuration!
    expect(Phronomy.configuration.tracer).to be_a(Phronomy::Tracing::NullTracer)
    expect(Phronomy.configuration.trace_pii).to be(false)
    expect(tool_class.new.call({value: "abcdef"})).to eq("abcdef")
    expect(Phronomy::Tracing::Observation.trace("reset", input: "input") { ["result", nil] }).to eq("result")
    expect(old_tracer.spans).to be_empty
  end

  [false, true].each do |record_pii|
    it "finishes an automatic span with its original tracer and trace_pii=#{record_pii} after reset" do
      first = tracer_class.new
      second = tracer_class.new
      Phronomy.configure { |config|
        config.tracer = first
        config.trace_pii = record_pii
      }
      task = Phronomy::TaskResult.deferred
      Phronomy::Tracing::Automatic.observe_task(task, "pending", input: "secret input", user_id: "user")
      Phronomy.reset_configuration!
      Phronomy.configure { |config|
        config.tracer = second
        config.trace_pii = !record_pii
      }
      task.complete("secret output")
      expect(task.wait_result).to eq("secret output")
      expect(first.spans.first[:input]).to eq(record_pii ? "secret input" : "[REDACTED]")
      expect(first.spans.first[:output]).to eq(record_pii ? "secret output" : "[REDACTED]")
      expect(first.spans.first.key?(:user_id)).to be(record_pii)
      expect(second.spans).to be_empty
      Phronomy::Tracing::Automatic.trace("next", input: "next input") { "next output" }
      expect(second.spans.first[:output]).to eq(record_pii ? "[REDACTED]" : "next output")
    end

    it "keeps Observation trace_pii=#{record_pii} for the entire block despite configuration writes" do
      first = tracer_class.new
      second = tracer_class.new
      usage = Phronomy::LLMAdapter::TokenUsage.new(input: 2, output: 3)
      Phronomy.configure { |config|
        config.tracer = first
        config.trace_pii = record_pii
      }
      result = Phronomy::Tracing::Observation.trace("block", input: "secret input") do
        Phronomy.configure { |config|
          config.tracer = second
          config.trace_pii = !record_pii
        }
        ["secret output", usage]
      end
      expect(result).to eq("secret output")
      expect(first.spans.first[:input]).to eq(record_pii ? "secret input" : "[REDACTED]")
      expect(first.spans.first[:output]).to eq(record_pii ? "secret output" : "[REDACTED]")
      expect(first.spans.first[:usage]).to be(usage)
      expect(second.spans).to be_empty
    end
  end

  it "keeps automatic error redaction selected at span start" do
    tracer = tracer_class.new
    Phronomy.configure { |config|
      config.tracer = tracer
      config.trace_pii = false
    }
    handle = Phronomy::Tracing::Automatic.start("error", input: "secret")
    Phronomy.configuration.trace_pii = true
    Phronomy::Tracing::Automatic.finish(handle, error: RuntimeError.new("secret failure"))
    expect(tracer.spans.first[:error].message).to eq("[REDACTED]")
    expect(tracer.spans.first[:error].backtrace).to eq([])
  end

  it "retains Context's constructor-time tracer even if configuration changes before preparation" do
    first = tracer_class.new
    second = tracer_class.new
    Phronomy.configuration.tracer = first
    assembly = Phronomy::Context::Assembly.new
    Phronomy.configuration.tracer = second
    prepare_context(assembly)
    expect(first.spans.map { |span| span[:name] }).to eq(["context_policy"])
    expect(second.spans).to be_empty
    prepare_context(Phronomy::Context::Assembly.new)
    expect(second.spans.map { |span| span[:name] }).to eq(["context_policy"])
  end

  it "preserves explicit Context tracer injection when the configured tracer is nil" do
    explicit = tracer_class.new
    Phronomy.configuration.tracer = nil
    prepare_context(Phronomy::Context::Assembly.new(tracer: explicit))
    expect(explicit.spans.map { |span| span[:name] }).to eq(["context_policy"])
  end
end
