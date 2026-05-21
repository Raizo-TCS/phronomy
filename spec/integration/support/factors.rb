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
  # @param label [String] "none" | "window" | "composite"
  # @param opts  [Hash]   optional overrides
  #   :k              – Retrieval::Recent k (default 10)
  #   :sources        – Retrieval::Composite sources array
  #                     each entry: { retrieval: <Retrieval::Base>, weight: Float }
  # @return [Phronomy::Memory::ConversationManager, nil]
  # ---------------------------------------------------------------------------
  def self.memory(label, **opts)
    case label
    when "none"
      nil
    when "window"
      Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Recent.new(k: opts.fetch(:k, 10))
      )
    when "composite"
      sources = opts[:sources] || [
        {retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 5), weight: 1.0}
      ]
      Phronomy::Memory::ConversationManager.new(
        storage: Phronomy::Memory::Storage::InMemory.new,
        retrieval: Phronomy::Memory::Retrieval::Composite.new(sources: sources)
      )
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

  # ---------------------------------------------------------------------------
  # Context management factor helpers
  # ---------------------------------------------------------------------------

  # Factor: ctx_static_knowledge
  #
  # Returns an Array of StaticKnowledge sources for the given label.
  #
  # @param label [String] "none" | "single" | "multi"
  # @return [Array<Phronomy::KnowledgeSource::StaticKnowledge>]
  def self.static_knowledge_sources(label)
    case label
    when "none"
      []
    when "single"
      [Phronomy::KnowledgeSource::StaticKnowledge.new("Policy: be concise and helpful.")]
    when "multi"
      [
        Phronomy::KnowledgeSource::StaticKnowledge.new("Policy: be concise and helpful."),
        Phronomy::KnowledgeSource::StaticKnowledge.new("Guide: always cite sources when possible.")
      ]
    else
      raise ArgumentError, "Unknown ctx_static_knowledge label: #{label}"
    end
  end

  # Factor: ctx_on_trim
  #
  # Returns a Proc or nil for on_trim based on the label.
  # The callback receives a TrimContext; :remove_some drops the first message.
  #
  # @param label [String] "none" | "remove_none" | "remove_some"
  # @return [Proc, nil]
  def self.on_trim_callback(label)
    case label
    when "none"
      nil
    when "remove_none"
      proc { |_ctx| }
    when "remove_some"
      proc do |ctx|
        first = ctx.message_elements.first
        ctx.remove(first[:seq]) if first
      end
    else
      raise ArgumentError, "Unknown ctx_on_trim label: #{label}"
    end
  end

  # Factor: ctx_on_compaction_trigger
  #
  # Returns a Proc or nil for on_compaction_trigger based on the label.
  #
  # @param label [String] "none" | "false" | "true"
  # @return [Proc, nil]
  def self.on_compaction_trigger_callback(label)
    case label
    when "none"
      nil
    when "false"
      proc { |_ctx| false }
    when "true"
      proc { |_ctx| true }
    else
      raise ArgumentError, "Unknown ctx_on_compaction_trigger label: #{label}"
    end
  end

  # Factor: ctx_on_compact
  #
  # Returns a Proc or nil for on_compact based on the label.
  # :summarise_range compacts the first message (if any) with a fixed summary.
  # :multi_range performs two separate compact calls on non-overlapping ranges.
  #
  # @param label [String] "none" | "summarise_range" | "multi_range"
  # @return [Proc, nil]
  def self.on_compact_callback(label)
    case label
    when "none"
      nil
    when "summarise_range"
      proc do |ctx|
        next if ctx.message_elements.empty?
        ctx.compact(0..0) { |_| "Earlier conversation summary." }
      end
    when "multi_range"
      proc do |ctx|
        els = ctx.message_elements
        next if els.length < 2
        ctx.compact(0..0) { |_| "First compaction summary." }
      end
    else
      raise ArgumentError, "Unknown ctx_on_compact label: #{label}"
    end
  end

  # Builds an agent class configured with context management callbacks.
  #
  # @param static_knowledge_label  [String] ctx_static_knowledge factor label
  # @param on_trim_label           [String] ctx_on_trim factor label
  # @param on_trigger_label        [String] ctx_on_compaction_trigger factor label
  # @param on_compact_label        [String] ctx_on_compact factor label
  # @return [Class] anonymous Agent::Base subclass
  def self.context_agent(
    static_knowledge_label: "none",
    on_trim_label: "none",
    on_trigger_label: "none",
    on_compact_label: "none"
  )
    sources = static_knowledge_sources(static_knowledge_label)
    trim_cb = on_trim_callback(on_trim_label)
    trigger_cb = on_compaction_trigger_callback(on_trigger_label)
    compact_cb = on_compact_callback(on_compact_label)

    Class.new(Phronomy::Agent::Base) do
      model LM_STUDIO_MODEL
      provider :openai
      instructions "You are a helpful assistant."
      static_knowledge(*sources) unless sources.empty?
      on_trim(&trim_cb) if trim_cb
      on_compaction_trigger(&trigger_cb) if trigger_cb
      on_compact(&compact_cb) if compact_cb
    end
  end

  # ===========================================================================
  # GROUP 25 — BEFORE_COMPLETION HOOK
  # ===========================================================================

  # Returns a hook callable for the given bc_hook_return factor label.
  # The callable accepts a BeforeCompletionContext and returns a Hash (or nil).
  #
  # @param return_label [String] bc_hook_return factor label
  # @return [Proc]
  def self.bc_hook_callable(return_label)
    case return_label
    when "nil"
      ->(_ctx) {}
    when "empty_hash"
      ->(_ctx) { {} }
    when "param_merge"
      ->(_ctx) { {temperature: 0.1} }
    when "model_override"
      ->(_ctx) { {model: LM_STUDIO_MODEL} }
    else
      raise ArgumentError, "Unknown bc_hook_return label: #{return_label}"
    end
  end

  # Returns a fresh agent class for the given bc_agent_class label.
  #
  # @param label [String] "base" or "react"
  # @return [Class] anonymous subclass of Agent::Base or Agent::ReactAgent
  def self.bc_agent_class(label)
    case label
    when "base"
      Class.new(Phronomy::Agent::Base) do
        model LM_STUDIO_MODEL
        provider :openai
        instructions "You are a helpful assistant."
      end
    when "react"
      Class.new(Phronomy::Agent::ReactAgent) do
        model LM_STUDIO_MODEL
        provider :openai
        instructions "You are a helpful assistant."
        tools IntegrationFactors::CalculatorTool
      end
    else
      raise ArgumentError, "Unknown bc_agent_class label: #{label}"
    end
  end

  # Builds an agent instance with the before_completion hook configured at
  # the appropriate tier(s). Returns the agent instance.
  # Callers are responsible for resetting global config after the test.
  #
  # @param tier_label   [String] bc_hook_tier factor label
  # @param return_label [String] bc_hook_return factor label
  # @param klass        [Class]  agent class (from bc_agent_class)
  # @return [Phronomy::Agent::Base]
  def self.bc_build_agent(tier_label:, return_label:, klass:)
    callable = (tier_label == "none") ? nil : bc_hook_callable(return_label)

    case tier_label
    when "none"
      klass.new
    when "global"
      Phronomy.configuration.before_completion = callable
      klass.new
    when "class_level"
      klass.before_completion callable
      klass.new
    when "instance_level"
      instance = klass.new
      instance.before_completion = callable
      instance
    when "multi_tier"
      Phronomy.configuration.before_completion = callable
      klass.before_completion callable
      instance = klass.new
      instance.before_completion = callable
      instance
    else
      raise ArgumentError, "Unknown bc_hook_tier label: #{tier_label}"
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 26 — MULTI-AGENT HANDOFF helpers
  # ---------------------------------------------------------------------------

  # Model identifier used in all Group 26 agents.
  LM_MODEL_26 = LM_STUDIO_MODEL

  # Builds a pair of anonymous agent classes for linear handoff tests.
  # Returns [entry_class, target_class].
  def self.handoff_linear_classes
    entry_klass = Class.new(Phronomy::Agent::ReactAgent) do
      model LM_MODEL_26
      provider :openai
      instructions "You are a triage assistant. Route billing questions to billing."
    end
    target_klass = Class.new(Phronomy::Agent::Base) do
      model LM_MODEL_26
      provider :openai
      instructions "You are a billing assistant. Answer billing questions."
    end
    [entry_klass, target_klass]
  end

  # Builds a hub + spoke agent setup for hub_spoke topology tests.
  # Returns [hub_instance, spoke1_instance, spoke2_instance].
  def self.handoff_hub_spoke_instances(spoke_count: 2)
    spoke_klasses = (1..spoke_count).map do |i|
      Class.new(Phronomy::Agent::Base) do
        model LM_MODEL_26
        provider :openai
        instructions "You are spoke agent #{i}."
      end
    end

    hub_klass = Class.new(Phronomy::Agent::ReactAgent) do
      model LM_MODEL_26
      provider :openai
      instructions "You are a hub agent. Route to spokes when needed."
    end

    hub = hub_klass.new
    spokes = spoke_klasses.map(&:new)
    [hub, *spokes]
  end

  # ---------------------------------------------------------------------------
  # GROUP 27 — RAILS WEBSOCKET AGENT JOB helpers
  # ---------------------------------------------------------------------------

  # Model identifier used in all Group 27 agents.
  LM_MODEL_27 = LM_STUDIO_MODEL

  # Builds an anonymous Base or ReactAgent class for AgentJob tests.
  # @param label [String] "base" or "react"
  # @return [Class<Phronomy::Agent::Base>]
  def self.job_agent_class(label)
    case label
    when "base"
      Class.new(Phronomy::Agent::Base) do
        model LM_MODEL_27
        provider :openai
        instructions "You are a helpful assistant."
      end
    when "react"
      Class.new(Phronomy::Agent::ReactAgent) do
        model LM_MODEL_27
        provider :openai
        instructions "You are a helpful assistant."
        tools IntegrationFactors::CalculatorTool
      end
    else
      raise ArgumentError, "Unknown job_agent_type label: #{label}"
    end
  end

  # Builds a config hash with the given style (symbol or string keys).
  # @param label [String] "symbol_keys" or "string_keys"
  # @return [Hash]
  def self.job_config(label)
    case label
    when "symbol_keys" then {thread_id: nil}
    when "string_keys" then {"thread_id" => nil}
    else raise ArgumentError, "Unknown job_config_style label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers for Group 28: Workflow Wait State / Phase
  # ---------------------------------------------------------------------------

  # Builds a Workflow (node_a -> wait_state(:awaiting_node_b) -> node_b -> finish)
  # that halts at the wait state and resumes via the :resume event.
  #
  # The state class has a single :replace field `value` (String).
  #
  # @param state_class [Class] a class that includes Phronomy::WorkflowContext
  # @return [Phronomy::WorkflowRunner]
  def self.wait_state_resume_graph(state_class)
    store = Phronomy::StateStore::InMemory.new
    Phronomy.configure { |c| c.default_state_store = store }

    Phronomy::Workflow.define(state_class) do
      initial :node_a
      state :node_a
      wait_state :awaiting_node_b
      state :node_b
      entry :node_a, ->(s) { s.value = "#{s.value}:a" }
      entry :node_b, ->(s) { s.value = "#{s.value}:b" }
      transition from: :node_a, to: :awaiting_node_b
      transition from: :node_b, to: :__finish__
      transition from: :awaiting_node_b, on: :resume, to: :node_b
    end
  end

  # Builds a Workflow (node_a -> wait_state(:awaiting_node_b) -> node_b -> finish)
  # using a named resume event. The wait state halts between node_a and node_b.
  #
  # @param state_class [Class] a class that includes Phronomy::WorkflowContext
  # @param resume_event [Symbol] event name for send_event (default :proceed)
  # @return [Phronomy::WorkflowRunner]
  def self.wait_state_graph(state_class, resume_event: :proceed)
    store = Phronomy::StateStore::InMemory.new
    Phronomy.configure { |c| c.default_state_store = store }

    Phronomy::Workflow.define(state_class) do
      initial :node_a
      state :node_a
      wait_state :awaiting_node_b
      state :node_b
      entry :node_a, ->(s) { s.value = "#{s.value}:a" }
      entry :node_b, ->(s) { s.value = "#{s.value}:b" }
      transition from: :node_a, to: :awaiting_node_b
      transition from: :node_b, to: :__finish__
      transition from: :awaiting_node_b, on: resume_event, to: :node_b
    end
  end

  # Resets the default state store to nil after a wait_state test.
  def self.reset_state_store
    Phronomy.configure { |c| c.default_state_store = nil }
  end

  # ---------------------------------------------------------------------------
  # Group 29 — File State Store helpers
  # ---------------------------------------------------------------------------

  # Returns a new Phronomy::StateStore::File instance.
  #
  # @param dir_type [String] "default" or "custom"
  # @param custom_dir [String, nil] path used when dir_type == "custom"
  # @return [Phronomy::StateStore::File]
  def self.file_store(dir_type, custom_dir: nil)
    case dir_type
    when "default"
      Phronomy::StateStore::File.new
    when "custom"
      raise ArgumentError, "custom_dir is required when dir_type is 'custom'" unless custom_dir
      Phronomy::StateStore::File.new(dir: custom_dir)
    else
      raise ArgumentError, "Unknown file_store dir_type: #{dir_type}"
    end
  end

  # Returns a thread_id string for the given thread_id_type.
  #
  # @param thread_id_type [String] "simple" or "special_chars"
  # @param base [String] base identifier (appended to make it unique per test)
  # @return [String]
  def self.file_store_thread_id(thread_id_type, base: "t1")
    case thread_id_type
    when "simple"
      "thread-#{base}"
    when "special_chars"
      "user@host/#{base}"
    else
      raise ArgumentError, "Unknown file_store_thread_id_type: #{thread_id_type}"
    end
  end

  # Builds a two-step Workflow with a wait_state, backed by the given store.
  # node_a appends ":a" to value; node_b appends ":b".
  #
  # @param state_class [Class] includes Phronomy::WorkflowContext
  # @param store [Phronomy::StateStore::Base]
  # @return [Phronomy::WorkflowRunner]
  def self.file_store_workflow(state_class, store:)
    Phronomy::Workflow.define(state_class, state_store: store) do
      initial :node_a
      state :node_a
      wait_state :awaiting_node_b
      state :node_b
      entry :node_a, ->(s) { s.value = "#{s.value}:a" }
      entry :node_b, ->(s) { s.value = "#{s.value}:b" }
      transition from: :node_a, to: :awaiting_node_b
      transition from: :node_b, to: :__finish__
      transition from: :awaiting_node_b, on: :resume, to: :node_b
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 30 — APPROVAL RESUME helpers
  # ---------------------------------------------------------------------------

  # Model identifier used in all Group 30 agents.
  LM_MODEL_30 = LM_STUDIO_MODEL

  # Returns an anonymous approval-required tool class whose #execute returns a
  # fixed string.  The tool is registered with requires_approval: true so that
  # the suspension/resume path is exercised.
  #
  # @param result_value [String] value returned by the tool's execute method
  # @return [Class]
  def self.approval_tool(result_value: "approval_tool_result")
    Class.new(Phronomy::Tool::Base) do
      tool_name "approval_required_tool"
      description "A tool that requires approval"
      param :query, type: :string, desc: "Input for the tool"
      requires_approval true

      define_method(:execute) do |query:|
        result_value
      end
    end
  end

  # Returns a second approval-required tool for multi-tool test scenarios.
  #
  # @param result_value [String] value returned by the tool's execute method
  # @return [Class]
  def self.second_approval_tool(result_value: "second_approval_tool_result")
    Class.new(Phronomy::Tool::Base) do
      tool_name "second_approval_required_tool"
      description "A second tool that requires approval"
      param :query, type: :string, desc: "Input for the tool"
      requires_approval true

      define_method(:execute) do |query:|
        result_value
      end
    end
  end

  # Builds an anonymous Agent::Base subclass pre-configured with the given
  # approval-required tool(s) for the suspend/resume path.
  #
  # @param tool_classes [Array<Class>] tool classes to register (must all have requires_approval: true)
  # @return [Class]
  def self.approval_resume_agent(*tool_classes)
    Class.new(Phronomy::Agent::Base) do
      model LM_MODEL_30
      provider :openai
      instructions "You are a helpful assistant. Use tools when asked."
      tools(*tool_classes)
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 31 — SHARED STATE helpers
  # ---------------------------------------------------------------------------

  LM_MODEL_31 = LM_STUDIO_MODEL

  # Returns an anonymous Phronomy::Agent::Base subclass suitable for use as a
  # SharedState researcher.  The class has no tools of its own; SharedState
  # injects write_finding and read_store automatically.
  #
  # @return [Class]
  def self.ss_researcher_class
    Class.new(Phronomy::Agent::Base) do
      model LM_MODEL_31
      provider :openai
      instructions "You are a research assistant."
    end
  end

  # Builds a SharedState team class configured according to the given factor
  # labels.
  #
  # @param termination [Symbol] :max_cycles | :terminate_when | :timeout
  # @param instruction [Symbol] :present | :absent
  # @param coordination [Symbol] :custom | :default
  # @param aggregate [Symbol] :with_block | :none
  # @return [Class<Phronomy::Agent::SharedState>]
  def self.ss_team_class(termination:, instruction:, coordination:, aggregate:, researcher:)
    instr_text = (instruction == :present) ? "Focus only on security aspects." : nil

    Class.new(Phronomy::Agent::SharedState) do
      case termination
      when :max_cycles
        max_cycles 2
      when :terminate_when
        max_cycles 100
        terminate_when { |store| store.size > 0 }
      when :timeout
        timeout 0
        max_cycles 100
      end

      if coordination == :custom
        coordination "CUSTOM COORDINATION GUIDE: Share all findings."
      end

      if instr_text
        member researcher, instruction: instr_text
      else
        member researcher
      end

      if aggregate == :with_block
        aggregate { |store| store.read_all.map { |f| f[:content] }.join(" | ") }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 32 — TEAM COORDINATOR helpers
  # ---------------------------------------------------------------------------

  LM_MODEL_32 = LM_STUDIO_MODEL

  # Returns an anonymous worker Agent::Base subclass for TeamCoordinator tests.
  # The worker simply echoes back the task description as its output.
  # To simulate a failure, pass failing: true.
  #
  # @param failing [Boolean] when true, invoke raises RuntimeError
  # @return [Class]
  def self.tc_worker_class(failing: false)
    Class.new(Phronomy::Agent::Base) do
      model LM_MODEL_32
      provider :openai
      instructions "You are a worker agent."

      if failing
        define_method(:invoke) do |input, messages: [], thread_id: nil, config: {}|
          raise "worker_error"
        end
      end
    end
  end

  # Builds a TeamCoordinator class configured according to the given factor
  # labels.
  #
  # @param pool_size [Symbol] :single | :multi
  # @param on_error [Symbol] :raise | :skip
  # @param aggregate [Symbol] :with_block | :none
  # @param worker [Class] worker agent class to use in the pool
  # @return [Class<Phronomy::Agent::TeamCoordinator>]
  def self.tc_team_class(pool_size:, on_error:, aggregate:, worker:)
    size = (pool_size == :single) ? 1 : 2
    err = on_error

    Class.new(Phronomy::Agent::TeamCoordinator) do
      coordinator_model LM_MODEL_32
      coordinator_provider :openai
      coordinator_instructions "You are a task coordinator. Use enqueue_task to " \
        "add tasks, then call finalize when done."

      pool size: size, agent: worker, on_error: err

      if aggregate == :with_block
        aggregate { |assignments| assignments.map { |a| a[:result] }.compact.join(" | ") }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 33 — GENERATOR VERIFIER helpers
  # ---------------------------------------------------------------------------

  LM_MODEL_33 = LM_STUDIO_MODEL

  # Returns an anonymous Agent::Base subclass whose LLM call is stubbed by
  # WebMock; suitable for use as draft_agent or review_agent in GeneratorVerifier
  # integration tests.
  #
  # @return [Class<Phronomy::Agent::Base>]
  def self.gv_agent_class
    Class.new(Phronomy::Agent::Base) do
      model LM_MODEL_33
      provider :openai
    end
  end

  # Builds a GeneratorVerifier pipeline with the given factor labels.
  #
  # @param approval_outcome [Symbol] :approved | :rejected
  # @param iteration_limit  [Symbol] :one | :three
  # @param raise_policy     [Symbol] :raise | :no_raise
  # @return [Phronomy::GeneratorVerifier]
  def self.gv_pipeline(approval_outcome:, iteration_limit:, raise_policy:)
    draft_agent = gv_agent_class
    review_agent = gv_agent_class
    max_iter = (iteration_limit == :one) ? 1 : 3
    raise_flag = (raise_policy == :raise)

    Phronomy::GeneratorVerifier.new(
      draft_agent: draft_agent,
      review_agent: review_agent,
      draft_prompt_builder: lambda { |input, feedback|
        base = "Draft question: #{input}"
        feedback ? "#{base}\nPrevious review feedback: #{feedback}" : base
      },
      review_prompt_builder: ->(input, _draft, _citations) { "Review draft for: #{input}" },
      confidence_threshold: 0.7,
      max_iterations: max_iter,
      raise_if_untrusted: raise_flag
    )
  end

  # Returns a WebMock-compatible draft response JSON for a given confidence.
  # @param confidence [Float]
  # @return [String]
  def self.gv_draft_response(confidence: 0.9)
    JSON.generate(
      answer: "The answer is 42.",
      confidence: confidence,
      citations: [{source: "policy.md", excerpt: "Key fact."}]
    )
  end

  # Returns a WebMock-compatible review response JSON.
  # @param approved [Boolean]
  # @return [String]
  def self.gv_review_response(approved: true)
    score = approved ? 0.85 : 0.3
    feedback = approved ? "" : "Missing citation for claim X."
    JSON.generate(approved: approved, score: score, feedback: feedback)
  end

  # ---------------------------------------------------------------------------
  # GROUP 34 — ORCHESTRATOR helpers
  # ---------------------------------------------------------------------------

  LM_MODEL_34 = LM_STUDIO_MODEL

  # Returns an anonymous Agent::Base subclass suitable as an Orchestrator
  # subagent.  Its LLM response is provided via WebMock stubs.
  #
  # @return [Class<Phronomy::Agent::Base>]
  def self.orch_subagent_class
    Class.new(Phronomy::Agent::Base) do
      model LM_MODEL_34
      provider :openai
      instructions "You are a specialist subagent."
    end
  end

  # Builds an Orchestrator class with the given factors.
  # Only used for the :declarative delegation mode.
  #
  # @param subagent_count [Symbol] :single | :multiple
  # @param on_error       [Symbol] :raise | :skip
  # @return [Class<Phronomy::Agent::Orchestrator>]
  def self.orch_declarative_class(subagent_count:, on_error:)
    sa1 = orch_subagent_class
    sa2 = orch_subagent_class
    err = on_error

    Class.new(Phronomy::Agent::Orchestrator) do
      model LM_MODEL_34
      provider :openai
      instructions "You are an orchestrator. Use dispatch_to tools to delegate."

      subagent :worker_a, sa1, on_error: err
      subagent :worker_b, sa2, on_error: err if subagent_count == :multiple
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 35 — VECTOR STORE DIMENSION VALIDATION helpers (#98)
  # ---------------------------------------------------------------------------

  # Returns a fresh InMemory store with the given dimension initialisation.
  #
  # @param label [String] "explicit" | "inferred"
  # @return [Phronomy::VectorStore::InMemory]
  def self.vs_store(label)
    case label
    when "explicit" then Phronomy::VectorStore::InMemory.new(dimension: 2)
    when "inferred" then Phronomy::VectorStore::InMemory.new
    else raise ArgumentError, "Unknown vs_dimension_init label: #{label}"
    end
  end

  # Returns an embedding whose size matches or mismatches the reference dimension (2).
  #
  # @param label [String] "match" | "mismatch"
  # @return [Array<Float>]
  def self.vs_embedding(label)
    case label
    when "match" then [0.6, 0.8]
    when "mismatch" then [0.6, 0.8, 0.0]
    else raise ArgumentError, "Unknown vs_size_match label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 36 — BOUNDED DISPATCH_PARALLEL helpers (#99)
  # ---------------------------------------------------------------------------

  # Returns the max_concurrency value for the given label.
  #
  # @param label      [String]  "nil" | "one" | "gt_tasks"
  # @param task_count [Integer] number of tasks (used for "gt_tasks")
  # @return [Integer, nil]
  def self.bp_max_concurrency(label, task_count: 3)
    case label
    when "nil" then nil
    when "one" then 1
    when "gt_tasks" then task_count + 5
    else raise ArgumentError, "Unknown bp_max_concurrency label: #{label}"
    end
  end

  # Returns an array of task hashes for dispatch_parallel, mixed succeed/fail
  # according to the given outcome label.
  #
  # @param label [String] "all_succeed" | "some_fail" | "all_fail"
  # @return [Array<Hash>]
  def self.bp_tasks(label)
    good = Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) { |input, config: {}| {output: "ok:#{input}", messages: []} }
    end
    bad = Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) { |*| raise "task_error" }
    end

    case label
    when "all_succeed"
      [
        {agent: good, input: "t0"},
        {agent: good, input: "t1"},
        {agent: good, input: "t2"}
      ]
    when "some_fail"
      [
        {agent: good, input: "t0"},
        {agent: bad, input: "t1"},
        {agent: good, input: "t2"}
      ]
    when "all_fail"
      [
        {agent: bad, input: "t0"},
        {agent: bad, input: "t1"},
        {agent: bad, input: "t2"}
      ]
    else
      raise ArgumentError, "Unknown bp_task_outcome label: #{label}"
    end
  end

  # Returns a minimal Orchestrator subclass for dispatch_parallel / fan_out tests.
  #
  # @return [Class<Phronomy::Agent::Orchestrator>]
  def self.bp_orchestrator_class
    Class.new(Phronomy::Agent::Orchestrator)
  end
end
