# frozen_string_literal: true

# Shared helpers that map integration_test_factors.yaml label values to
# concrete Ruby objects / configuration values used across all pairwise
# integration specs.
#
# Usage (from any spec file):
#   require_relative "support/factors"
#
#   agent_klass = IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_single"))
#   memory      = IntegrationFactors.memory("window")
#   budget      = IntegrationFactors.token_budget("generous")
#
# Add methods for new factors as new spec groups are implemented.
# Fixture classes are defined here as named constants so they can be
# shared without re-opening anonymous classes.

module IntegrationFactors
  LM_STUDIO_MODEL = "openai/gpt-oss-20b"

  # ---------------------------------------------------------------------------
  # Fixture Tool classes
  # ---------------------------------------------------------------------------

  class CalculatorTool < Phronomy::Tool::Base
    description "Adds two integers and returns the sum as a string"
    param :a, type: :integer, desc: "First integer"
    param :b, type: :integer, desc: "Second integer"

    def execute(a:, b:)
      (a + b).to_s
    end
  end

  class WeatherTool < Phronomy::Tool::Base
    description "Returns a brief weather description for a city"
    param :city, type: :string, desc: "Name of the city"

    def execute(city:)
      "Sunny and 22°C in #{city}."
    end
  end

  class AlwaysErrorTool < Phronomy::Tool::Base
    description "Always raises a RuntimeError (used to test on_error: :raise)"
    param :input, type: :string, desc: "Any string input"

    def execute(input:)
      raise "Simulated tool error for input: #{input}"
    end
  end

  class ReturnEmptyOnErrorTool < Phronomy::Tool::Base
    description "Always raises but returns empty (used to test on_error: :return_empty)"
    param :input, type: :string, desc: "Any string input"

    on_error :return_empty

    def execute(input:)
      raise "Simulated tool error for input: #{input}"
    end
  end

  # Used for tool_param_enum tests.
  # valid_value  = one of "Tokyo", "London", "Paris"
  # invalid_value = any other string — execute raises, triggering ToolError
  class EnumCitySelectorTool < Phronomy::Tool::Base
    description "Returns a short fact about a supported city: Tokyo, London, or Paris"
    on_schema_error :raise
    param :city, type: :string,
      desc: "City to look up; must be one of: Tokyo, London, Paris",
      enum: %w[Tokyo London Paris]

    def execute(city:)
      case city
      when "Tokyo" then "Tokyo is the capital and most populous city of Japan."
      when "London" then "London is the capital city of England and the United Kingdom."
      when "Paris" then "Paris is the capital and most populous city of France."
      else raise "Unknown city '#{city}'; must be Tokyo, London, or Paris"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture Guardrail classes
  # ---------------------------------------------------------------------------

  class PassingInputGuardrail < Phronomy::Guardrail::InputGuardrail
    # no-op: always passes
    def check(_input)
    end
  end

  class BlockingInputGuardrail < Phronomy::Guardrail::InputGuardrail
    def check(_input)
      fail!("Blocked: input rejected by BlockingInputGuardrail")
    end
  end

  class PassingOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
    # no-op: always passes
    def check(_output)
    end
  end

  class BlockingOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
    def check(_output)
      fail!("Blocked: output rejected by BlockingOutputGuardrail")
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_class
  #
  # Builds an anonymous agent subclass pre-configured with the given tools.
  #
  # @param label [String] "base" | "react"
  # @param tools [Array, Hash] tool list in splat or hash form (default: [])
  # @return [Class]
  # ---------------------------------------------------------------------------
  def self.agent_class(label, tools: [])
    base_klass = (label == "react") ? Phronomy::Agent::ReactAgent : Phronomy::Agent::Base
    model_name = LM_STUDIO_MODEL
    tool_arg = tools

    Class.new(base_klass) do
      model model_name
      provider :openai  # directs to openai_api_base (LM Studio); sets assume_model_exists: true
      instructions "You are a helpful assistant. Use tools when they are useful."

      case tool_arg
      when Hash then self.tools(tool_arg)
      when Array then self.tools(*tool_arg) unless tool_arg.empty?
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: memory_type
  #
  # @param label [String] "none" | "window" | "summary" | "composite"
  # @param opts  [Hash]   optional overrides
  #   :k              – WindowMemory k (default 10)
  #   :max_tokens     – SummaryMemory max_tokens (default 4000)
  #   :summarizer_model – SummaryMemory summarizer_model (default nil)
  #   :sources        – CompositeMemory sources array (default single WindowMemory)
  # @return [Phronomy::Memory::Base, nil]
  # ---------------------------------------------------------------------------
  def self.memory(label, **opts)
    case label
    when "none"
      nil
    when "window"
      Phronomy::Memory::WindowMemory.new(k: opts.fetch(:k, 10))
    when "summary"
      Phronomy::Memory::SummaryMemory.new(
        max_tokens: opts.fetch(:max_tokens, 4000),
        summarizer_model: opts[:summarizer_model]
      )
    when "composite"
      sources = opts[:sources] || [
        {memory: Phronomy::Memory::WindowMemory.new(k: 5), weight: 1.0}
      ]
      Phronomy::Memory::CompositeMemory.new(sources: sources)
    when "entity"
      Phronomy::Memory::EntityMemory.new(k: opts.fetch(:k, 20))
    else
      raise ArgumentError, "Unknown memory_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_tools
  #
  # @param label [String] "none" | "splat_single" | "splat_multi" |
  #                       "hash_alias" | "hash_no_alias"
  # @return [Array, Hash]  value suitable for passing to .agent_class(tools: ...)
  # ---------------------------------------------------------------------------
  def self.tools(label)
    case label
    when "none" then []
    when "splat_single" then [CalculatorTool]
    when "splat_multi" then [CalculatorTool, WeatherTool]
    when "hash_alias" then {CalculatorTool => "calc"}
    when "hash_no_alias" then {CalculatorTool => nil}
    else raise ArgumentError, "Unknown agent_tools label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: thread_id
  #
  # @param label [String] "nil" | "present" | "different_threads"
  # @return [nil, String, Array<String>]
  # ---------------------------------------------------------------------------
  def self.thread_id(label)
    case label
    when "nil" then nil
    when "present" then "thread-001"
    when "different_threads" then ["thread-001", "thread-002"]
    else raise ArgumentError, "Unknown thread_id label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: memory_token_budget
  #
  # @param label [String] "nil" | "generous" | "tight"
  # @return [Phronomy::Context::TokenBudget, nil]
  # ---------------------------------------------------------------------------
  def self.token_budget(label)
    case label
    when "nil"
      nil
    when "generous"
      # 128k window, 4k output → ~124k for history; effectively unlimited
      Phronomy::Context::TokenBudget.new(context_window: 131_072, max_output_tokens: 4096)
    when "tight"
      # Very small window to force message trimming
      Phronomy::Context::TokenBudget.new(context_window: 256, max_output_tokens: 64)
    else
      raise ArgumentError, "Unknown memory_token_budget label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_guardrails
  #
  # @param label [String] "none" | "input_only" | "output_only" | "both" |
  #                       "blocking_input" | "blocking_output"
  # @return [Array<Phronomy::Guardrail::Base>]
  # ---------------------------------------------------------------------------
  def self.guardrails(label)
    case label
    when "none" then []
    when "input_only" then [PassingInputGuardrail.new]
    when "output_only" then [PassingOutputGuardrail.new]
    when "both" then [PassingInputGuardrail.new, PassingOutputGuardrail.new]
    when "blocking_input" then [BlockingInputGuardrail.new]
    when "blocking_output" then [BlockingOutputGuardrail.new]
    else raise ArgumentError, "Unknown agent_guardrails label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helper: attach a list of guardrail instances to an agent
  #
  # @param agent [Phronomy::Agent::Base] agent instance
  # @param list  [Array<Phronomy::Guardrail::Base>] guardrails to attach
  # ---------------------------------------------------------------------------
  def self.apply_guardrails(agent, list)
    list.each do |g|
      case g
      when Phronomy::Guardrail::InputGuardrail then agent.add_input_guardrail(g)
      when Phronomy::Guardrail::OutputGuardrail then agent.add_output_guardrail(g)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: prompt_template_type
  #
  # @param label [String] "human_only" | "with_system" | "multi_variable"
  # @return [Phronomy::PromptTemplate]
  # ---------------------------------------------------------------------------
  def self.prompt_template(label)
    case label
    when "human_only"
      Phronomy::PromptTemplate.new(template: "Answer this question: {{question}}")
    when "with_system"
      Phronomy::PromptTemplate.new(
        template: "Answer this question: {{question}}",
        system_template: "You are a {{role}} expert. Keep answers very short."
      )
    when "multi_variable"
      Phronomy::PromptTemplate.new(
        template: "Translate {{text}} from {{source_lang}} to {{target_lang}}.",
        system_template: "You are a professional translator."
      )
    else
      raise ArgumentError, "Unknown prompt_template_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: streaming_agent_class
  #
  # Builds an agent class pre-configured for streaming tests.
  #
  # @param label [String] "base" | "react"
  # @param tools [Array, Hash] tool list (default [])
  # @param instructions [String, Phronomy::PromptTemplate] instructions
  # @return [Class]
  # ---------------------------------------------------------------------------
  def self.streaming_agent_class(label, tools: [], instructions: "You are a helpful assistant.")
    base_klass = (label == "react") ? Phronomy::Agent::ReactAgent : Phronomy::Agent::Base
    model_name = LM_STUDIO_MODEL
    tool_arg = tools
    instr = instructions

    Class.new(base_klass) do
      model model_name
      provider :openai
      self.instructions(instr)

      case tool_arg
      when Hash then self.tools(tool_arg)
      when Array then self.tools(*tool_arg) unless tool_arg.empty?
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture: StubEmbeddings
  #
  # Deterministic embeddings adapter for use in tests that must not call an LLM.
  # Returns a 3-D vector derived from the text's character-sum so that
  # different texts produce different (but stable) vectors.
  # ---------------------------------------------------------------------------
  class StubEmbeddings < Phronomy::Embeddings::Base
    def embed(text)
      h = text.chars.sum(&:ord).to_f
      norm = Math.sqrt(3) * (h + 1)
      [h / norm, 1.0 / norm, 1.0 / norm]
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: embeddings_adapter_type
  #
  # @param label [String] "ruby_llm_default" | "ruby_llm_explicit_model" | "stub"
  # @return [Phronomy::Embeddings::Base]
  # ---------------------------------------------------------------------------
  LM_STUDIO_EMBEDDING_MODEL = "text-embedding-nomic-embed-text-v1.5"

  def self.embeddings_adapter(label)
    case label
    when "ruby_llm_default"
      Phronomy::Embeddings::RubyLLMEmbeddings.new
    when "ruby_llm_explicit_model"
      Phronomy::Embeddings::RubyLLMEmbeddings.new(
        model: LM_STUDIO_EMBEDDING_MODEL,
        provider: :openai,
        assume_model_exists: true
      )
    when "stub"
      StubEmbeddings.new
    else
      raise ArgumentError, "Unknown embeddings_adapter_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: vector_store_backend
  #
  # @param label [String] "in_memory" | "pgvector" | "redis_search"
  # @return [Phronomy::VectorStore::Base]
  # ---------------------------------------------------------------------------
  def self.vector_store(label)
    case label
    when "in_memory"
      Phronomy::VectorStore::InMemory.new
    when "pgvector"
      raise "Pgvector backend requires a running PostgreSQL + pgvector server"
    when "redis_search"
      raise "RedisSearch backend requires a running Redis with RediSearch module"
    else
      raise ArgumentError, "Unknown vector_store_backend label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: loader_type
  #
  # @param label [String] "plain_text" | "markdown_with_headings" |
  #                       "markdown_no_split" | "csv_with_headers"
  # @return [Phronomy::Loader::Base]
  # ---------------------------------------------------------------------------
  def self.loader(label)
    case label
    when "plain_text" then Phronomy::Loader::PlainTextLoader.new
    when "markdown_with_headings" then Phronomy::Loader::MarkdownLoader.new(split_on_headings: true)
    when "markdown_no_split" then Phronomy::Loader::MarkdownLoader.new(split_on_headings: false)
    when "csv_with_headers" then Phronomy::Loader::CsvLoader.new(headers: true)
    else raise ArgumentError, "Unknown loader_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: splitter_type
  #
  # @param label [String] "none" | "fixed_size" | "recursive"
  # @return [Phronomy::Splitter::Base, nil]
  # ---------------------------------------------------------------------------
  def self.splitter(label)
    case label
    when "none" then nil
    when "fixed_size" then Phronomy::Splitter::FixedSizeSplitter.new(chunk_size: 200, chunk_overlap: 20)
    when "recursive" then Phronomy::Splitter::RecursiveSplitter.new(chunk_size: 200, chunk_overlap: 20)
    else raise ArgumentError, "Unknown splitter_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: tracer_type
  #
  # Returns a configured tracer instance for the given label.
  # For :open_telemetry, the caller is responsible for setting up an OTel SDK
  # with an InMemorySpanExporter before calling this helper.
  #
  # @param label [String] "null_tracer" | "open_telemetry" | "langfuse"
  # @param exporter [Object, nil] InMemorySpanExporter for open_telemetry tests
  # @return [Phronomy::Tracing::Base]
  # ---------------------------------------------------------------------------
  def self.tracer(label, exporter: nil)
    case label
    when "null_tracer"
      Phronomy::Tracing::NullTracer.new
    when "open_telemetry"
      require "opentelemetry-sdk"
      OpenTelemetry::SDK.configure do |c|
        c.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
        )
      end
      Phronomy::Tracing::OpenTelemetryTracer.new(tracer_name: "phronomy_integration_test")
    when "langfuse"
      Phronomy::Tracing::LangfuseTracer.new(
        public_key: "pk-test",
        secret_key: "sk-test",
        host: "https://cloud.langfuse.com"
      )
    else
      raise ArgumentError, "Unknown tracer_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: eval_scorer_type
  #
  # @param label [String] "exact_match" | "includes_scorer" | "llm_judge"
  # @param model [String] RubyLLM model identifier (only used for llm_judge)
  # @return [Phronomy::Eval::Scorer::Base]
  # ---------------------------------------------------------------------------
  def self.eval_scorer(label, model: LM_STUDIO_MODEL)
    case label
    when "exact_match" then Phronomy::Eval::Scorer::ExactMatch.new
    when "includes_scorer" then Phronomy::Eval::Scorer::IncludesScorer.new
    when "llm_judge" then Phronomy::Eval::Scorer::LlmJudge.new(model: model)
    else raise ArgumentError, "Unknown eval_scorer_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: eval_dataset_size
  #
  # Returns a Dataset with the requested number of pre-defined EvalCase entries.
  # Each case tests simple arithmetic so responses are deterministic.
  #
  # @param label [String] "single" | "multi"
  # @return [Phronomy::Eval::Dataset]
  # ---------------------------------------------------------------------------
  def self.eval_dataset(label)
    all_pairs = [
      {input: "What is 2 + 2?", expected: "4"},
      {input: "What is 3 + 3?", expected: "6"},
      {input: "What is 5 + 5?", expected: "10"}
    ]
    count = case label
    when "single" then 1
    when "multi" then 3
    else raise ArgumentError, "Unknown eval_dataset_size label: #{label}"
    end
    Phronomy::Eval::Dataset.from_array(all_pairs.first(count))
  end

  # ---------------------------------------------------------------------------
  # Fixtures for Group 18: approval_spec
  # ---------------------------------------------------------------------------

  # A simple tool that does NOT require approval.
  class NoApprovalTool < Phronomy::Tool::Base
    tool_name "no_approval_tool"
    description "A test tool that does not require approval"
    param :value, type: :string, desc: "Input value"

    def execute(value:)
      "executed: #{value}"
    end
  end

  # A simple tool that DOES require approval.
  class RequiresApprovalTool < Phronomy::Tool::Base
    tool_name "requires_approval_tool"
    description "A test tool that requires approval"
    requires_approval true
    param :value, type: :string, desc: "Input value"

    def execute(value:)
      "executed: #{value}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: approval_tool_type
  #
  # @param label [String] "no_approval" | "requires_approval"
  # @return [Class] a Phronomy::Tool::Base subclass
  # ---------------------------------------------------------------------------
  def self.approval_tool_class(label)
    case label
    when "no_approval" then NoApprovalTool
    when "requires_approval" then RequiresApprovalTool
    else raise ArgumentError, "Unknown approval_tool_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: approval_handler_type
  #
  # Returns a lambda (or nil) to be passed to agent#on_approval_required.
  #
  # @param label [String] "none" | "approves" | "denies"
  # @return [Proc, nil]
  # ---------------------------------------------------------------------------
  def self.approval_handler(label)
    case label
    when "none" then nil
    when "approves" then ->(_tool_name, _args) { true }
    when "denies" then ->(_tool_name, _args) { false }
    else raise ArgumentError, "Unknown approval_handler_type label: #{label}"
    end
  end

  # Builds an agent instance (Base or ReactAgent) configured with the given
  # tool class and approval handler.
  #
  # @param agent_label  [String]  "base" | "react"
  # @param tool_class   [Class]   a Phronomy::Tool::Base subclass
  # @param handler      [Proc, nil] returned by .approval_handler
  # @return [Phronomy::Agent::Base]
  def self.approval_agent(agent_label, tool_class:, handler:)
    base_class = case agent_label
    when "base" then Phronomy::Agent::Base
    when "react" then Phronomy::Agent::ReactAgent
    else raise ArgumentError, "Unknown agent_class label: #{agent_label}"
    end

    agent_class = Class.new(base_class) do
      model "test-model"
      tools(tool_class)
    end

    agent = agent_class.new
    agent.on_approval_required(&handler) if handler
    agent
  end

  # ── on_schema_error helpers ──────────────────────────────────────────────

  # Builds an anonymous tool class that records its execute calls and supports
  # the given on_schema_error policy.
  #
  # @param policy_label   [String]  "return_error" | "raise" | "coerce"
  # @param execute_result [String]  value returned when execute runs normally
  # @return [Class]  a Phronomy::Tool::Base subclass
  def self.schema_error_tool(policy_label, execute_result: "ok")
    policy = policy_label.to_sym
    result = execute_result

    Class.new(Phronomy::Tool::Base) do
      tool_name "schema_test_tool"
      description "Integration test tool for schema error policies"
      on_schema_error policy
      param :count, type: :integer, desc: "An integer count"
      param :mode, type: :string, desc: "Mode", enum: %w[fast slow]

      define_method(:execute) do |count:, mode:|
        "#{result}: count=#{count} mode=#{mode}"
      end
    end
  end

  # ── async memory helpers ─────────────────────────────────────────────────

  # Builds a memory backend for async write tests.
  #
  # @param backend_label [String] "window" | "entity" | "ar_stub"
  # @param async         [Boolean]
  # @param queue         [Symbol]
  # @return [Phronomy::Memory::Base]
  def self.async_memory(backend_label, async: false, queue: :default)
    case backend_label
    when "window"
      Phronomy::Memory::WindowMemory.new(k: 5, async: async, queue: queue)
    when "entity"
      Phronomy::Memory::EntityMemory.new(k: 10, async: async, queue: queue)
    when "ar_stub"
      model_class = Class.new do
        def self.where(*)
          self
        end

        def self.order(*)
          self
        end

        def self.delete_all
        end

        def self.create!(**)
        end

        def self.to_a
          []
        end
      end
      Phronomy::Memory::ActiveRecordMemory.new(
        model_class: model_class, async: async, queue: queue
      )
    else
      raise ArgumentError, "Unknown async_memory backend_label: #{backend_label}"
    end
  end

  # ── tool retry helpers ────────────────────────────────────────────────────

  # Returns the exception class for a given label.
  #
  # @param label [String] "tool_error" | "runtime_error" | "guardrail_error"
  # @return [Class]
  def self.retry_exception_class(label)
    case label
    when "tool_error" then Phronomy::ToolError
    when "runtime_error" then RuntimeError
    when "guardrail_error" then Phronomy::GuardrailError
    else raise ArgumentError, "Unknown retry_exception_class label: #{label}"
    end
  end

  # Builds a tool class that raises +exception_class+ until +succeed_after+
  # total calls have been made. Sleep is replaced by a recording lambda.
  #
  # @param exception_class [Class]           exception to raise on each call
  # @param times           [Integer]         retry_on times:
  # @param wait            [Symbol, Numeric]  retry_on wait:
  # @param base            [Float]            retry_on base:
  # @param sleep_log       [Array]            array that sleep durations are appended to
  # @param succeed_after   [Integer, nil]     succeed when total calls reach this value
  # @return [Phronomy::Tool::Base subclass]
  def self.retry_tool(exception_class:, times:, wait:, base: 1.0,
    sleep_log: [], succeed_after: nil)
    calls = 0
    klass = Class.new(Phronomy::Tool::Base) do
      description "retry integration test tool"
      retry_on exception_class, times: times, wait: wait, base: base

      define_method(:execute) do |**_|
        calls += 1
        if succeed_after && calls >= succeed_after
          "recovered after #{calls}"
        else
          raise exception_class, "failure ##{calls}"
        end
      end
    end
    log = sleep_log
    klass._sleep_proc = ->(t) { log << t }
    klass
  end

  # Returns the RubyLLM error class corresponding to +label+.
  # Used by the LLM retry integration tests (Group 22).
  #
  # @param label [String] one of "rate_limit", "service_unavailable", "server_error"
  # @return [Class<RubyLLM::Error>]
  def self.llm_error_class(label)
    require "ruby_llm"
    case label
    when "rate_limit" then RubyLLM::RateLimitError
    when "service_unavailable" then RubyLLM::ServiceUnavailableError
    when "server_error" then RubyLLM::ServerError
    else raise ArgumentError, "Unknown llm_error_class label: #{label}"
    end
  end

  # Builds a fake LLM response object that satisfies the interface expected by
  # Agent::Base#invoke_once (response.content and response.tokens).
  #
  # @param content [String]
  # @return [Object]
  def self.fake_llm_response(content: "ok")
    tokens_stub = Struct.new(:input, :output, :cached, :cache_creation).new(1, 1, 0, 0)
    Struct.new(:content, :tokens, :messages).new(content, tokens_stub, [])
  end

  # Builds an Agent::Base subclass with retry_policy configured and the sleep
  # callable replaced by a recording lambda.
  #
  # @param times     [Integer]          retry_policy times:
  # @param wait      [Symbol, Numeric]  retry_policy wait:
  # @param base      [Float]            retry_policy base:
  # @param sleep_log [Array]            array that sleep durations are appended to
  # @return [Class<Phronomy::Agent::Base>]
  def self.retry_agent(times:, wait:, base: 1.0, sleep_log: [])
    klass = Class.new(Phronomy::Agent::Base) do
      model LM_STUDIO_MODEL
      provider :openai
      instructions "You are a test assistant."
      retry_policy times: times, wait: wait, base: base
    end
    log = sleep_log
    klass._sleep_proc = ->(t) { log << t }
    klass
  end
end
