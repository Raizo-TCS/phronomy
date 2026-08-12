# frozen_string_literal: true

# Shared helpers that map integration_test_factors.yaml label values to
# concrete Ruby objects / configuration values used across all pairwise
# integration specs.
#
# Usage (from any spec file):
#   require_relative "support/factors"
#
#   agent_klass = IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_single"))
#
# Add methods for new factors as new spec groups are implemented.
# Fixture classes are defined here as named constants so they can be
# shared without re-opening anonymous classes.

module IntegrationFactors
  LM_STUDIO_MODEL = "openai/gpt-oss-20b"

  # ---------------------------------------------------------------------------
  # Fixture Tool classes
  # ---------------------------------------------------------------------------

  class CalculatorTool < Phronomy::Agent::Context::Capability::Base
    description "Adds two integers and returns the sum as a string"
    param :a, type: :integer, desc: "First integer"
    param :b, type: :integer, desc: "Second integer"

    def execute(a:, b:)
      (a + b).to_s
    end
  end

  class WeatherTool < Phronomy::Agent::Context::Capability::Base
    description "Returns a brief weather description for a city"
    param :city, type: :string, desc: "Name of the city"

    def execute(city:)
      "Sunny and 22°C in #{city}."
    end
  end

  class AlwaysErrorTool < Phronomy::Agent::Context::Capability::Base
    description "Always raises a RuntimeError (used to test on_error: :raise)"
    param :input, type: :string, desc: "Any string input"

    def execute(input:)
      raise "Simulated tool error for input: #{input}"
    end
  end

  class SuppressOnErrorTool < Phronomy::Agent::Context::Capability::Base
    description "Always raises but suppresses the error"
    param :input, type: :string, desc: "Any string input"

    on_error :suppress

    def execute(input:)
      raise "Simulated tool error for input: #{input}"
    end
  end

  class EnumCitySelectorTool < Phronomy::Agent::Context::Capability::Base
    description "Returns a short fact about a supported city: Tokyo, London, Paris"
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
  # Fixture blocking filter classes
  # ---------------------------------------------------------------------------

  class PassingInputFilter < Phronomy::Filter::Base
    def call(value, **_ctx) = value
  end

  class BlockingInputFilter < Phronomy::Filter::Base
    def call(_value, **_ctx)
      block!("Blocked: input rejected by BlockingInputFilter")
    end
  end

  class PassingOutputFilter < Phronomy::Filter::Base
    def call(value, **_ctx) = value
  end

  class BlockingOutputFilter < Phronomy::Filter::Base
    def call(_value, **_ctx)
      block!("Blocked: output rejected by BlockingOutputFilter")
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_class
  # ---------------------------------------------------------------------------
  def self.agent_class(label, tools: [])
    base_klass = Phronomy::Agent::Base
    model_name = LM_STUDIO_MODEL
    tool_arg = tools
    defn_id = "integration-factor-#{SecureRandom.hex(4)}"

    Class.new(base_klass) do
      agent_definition id: defn_id, version: 1
      model model_name
      provider :openai
      instructions "You are a helpful assistant. Use tools when they are useful."

      case tool_arg
      when Hash then self.tools(tool_arg)
      when Array then self.tools(tool_arg.to_h { |t| [t, nil] }) unless tool_arg.empty?
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_tools
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
  # Factor: agent_guardrails (now: agent_filters)
  # ---------------------------------------------------------------------------
  def self.guardrails(label)
    case label
    when "none" then []
    when "input_only" then [PassingInputFilter.new]
    when "output_only" then [PassingOutputFilter.new]
    when "both" then [PassingInputFilter.new, PassingOutputFilter.new]
    when "blocking_input" then [BlockingInputFilter.new]
    when "blocking_output" then [BlockingOutputFilter.new]
    else raise ArgumentError, "Unknown agent_guardrails label: #{label}"
    end
  end

  def self.apply_guardrails(agent, list)
    list.each do |g|
      if g.is_a?(PassingInputFilter) || g.is_a?(BlockingInputFilter)
        agent.add_input_filter(g)
      else
        agent.add_output_filter(g)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: prompt_template_type
  # ---------------------------------------------------------------------------
  def self.prompt_template(label)
    case label
    when "human_only"
      Phronomy::Agent::Context::Instruction::PromptTemplate.new(template: "Answer this question: {{question}}")
    when "with_system"
      Phronomy::Agent::Context::Instruction::PromptTemplate.new(
        template: "Answer this question: {{question}}",
        system_template: "You are a {{role}} expert. Keep answers very short."
      )
    when "multi_variable"
      Phronomy::Agent::Context::Instruction::PromptTemplate.new(
        template: "Translate {{text}} from {{source_lang}} to {{target_lang}}.",
        system_template: "You are a professional translator."
      )
    else
      raise ArgumentError, "Unknown prompt_template_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: streaming_agent_class
  # ---------------------------------------------------------------------------
  def self.streaming_agent_class(label, tools: [], instructions: "You are a helpful assistant.")
    base_klass = Phronomy::Agent::Base
    model_name = LM_STUDIO_MODEL
    tool_arg = tools
    instr = instructions

    Class.new(base_klass) do
      model model_name
      provider :openai
      self.instructions(instr)

      case tool_arg
      when Hash then self.tools(tool_arg)
      when Array then self.tools(tool_arg.to_h { |t| [t, nil] }) unless tool_arg.empty?
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture: StubEmbeddings
  # ---------------------------------------------------------------------------
  class StubEmbeddings < Phronomy::VectorStore::Embeddings::Base
    def embed(text, _cancellation_token = nil)
      h = text.chars.sum(&:ord).to_f
      norm = Math.sqrt(3) * (h + 1)
      [h / norm, 1.0 / norm, 1.0 / norm]
    end
  end

  LM_STUDIO_EMBEDDING_MODEL = "text-embedding-nomic-embed-text-v1.5"

  def self.embeddings_adapter(label)
    case label
    when "ruby_llm_default"
      Phronomy::VectorStore::Embeddings::RubyLLMEmbeddings.new
    when "ruby_llm_explicit_model"
      Phronomy::VectorStore::Embeddings::RubyLLMEmbeddings.new(
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

  def self.loader(label)
    case label
    when "plain_text" then Phronomy::VectorStore::Loader::PlainTextLoader.new
    when "markdown_with_headings" then Phronomy::VectorStore::Loader::MarkdownLoader.new(split_on_headings: true)
    when "markdown_no_split" then Phronomy::VectorStore::Loader::MarkdownLoader.new(split_on_headings: false)
    when "csv_with_headers" then Phronomy::VectorStore::Loader::CsvLoader.new(headers: true)
    else raise ArgumentError, "Unknown loader_type label: #{label}"
    end
  end

  def self.splitter(label)
    case label
    when "none" then nil
    when "fixed_size" then Phronomy::VectorStore::Splitter::FixedSizeSplitter.new(chunk_size: 200, chunk_overlap: 20)
    when "recursive" then Phronomy::VectorStore::Splitter::RecursiveSplitter.new(chunk_size: 200, chunk_overlap: 20)
    else raise ArgumentError, "Unknown splitter_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: tracer_type
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

  def self.eval_scorer(label, model: LM_STUDIO_MODEL)
    case label
    when "exact_match" then Phronomy::Testing::Eval::Scorer::ExactMatch.new
    when "includes_scorer" then Phronomy::Testing::Eval::Scorer::IncludesScorer.new
    when "llm_judge" then Phronomy::Testing::Eval::Scorer::LlmJudge.new(model: model)
    else raise ArgumentError, "Unknown eval_scorer_type label: #{label}"
    end
  end

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
    Phronomy::Testing::Eval::Dataset.from_array(all_pairs.first(count))
  end

  class NoApprovalTool < Phronomy::Agent::Context::Capability::Base
    tool_name "no_approval_tool"
    description "A test tool that does not require approval"
    param :value, type: :string, desc: "Input value"

    def execute(value:)
      "executed: #{value}"
    end
  end

  class RequiresApprovalTool < Phronomy::Agent::Context::Capability::Base
    tool_name "requires_approval_tool"
    description "A test tool that requires approval"
    requires_approval true
    param :value, type: :string, desc: "Input value"

    def execute(value:)
      "executed: #{value}"
    end
  end

  def self.approval_tool_class(label)
    case label
    when "no_approval" then NoApprovalTool
    when "requires_approval" then RequiresApprovalTool
    else raise ArgumentError, "Unknown approval_tool_type label: #{label}"
    end
  end

  def self.approval_handler(label)
    case label
    when "none" then nil
    when "approves" then ->(_request) { :allow }
    when "denies" then ->(_request) { :reject }
    else raise ArgumentError, "Unknown approval_handler_type label: #{label}"
    end
  end

  def self.approval_agent(agent_label, tool_class:, handler:)
    base_class = Phronomy::Agent::Base
    defn_id = "integration-approval-#{SecureRandom.hex(4)}"

    agent_class = Class.new(base_class) do
      agent_definition id: defn_id, version: 1
      model "test-model"
      tools(tool_class => nil)
    end

    agent = agent_class.new
    agent.tool_approval_policy(&handler) if handler
    agent
  end

  def self.schema_error_tool(policy_label, execute_result: "ok")
    policy = policy_label.to_sym
    result = execute_result

    Class.new(Phronomy::Agent::Context::Capability::Base) do
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

  def self.fake_llm_response(content: "ok")
    tokens_stub = Struct.new(:input, :output, :cached, :cache_creation).new(1, 1, 0, 0)
    Struct.new(:content, :tokens, :messages).new(content, tokens_stub, [])
  end

  # ---------------------------------------------------------------------------
  # Context management helpers
  # ---------------------------------------------------------------------------
  def self.knowledge(label)
    case label
    when "none"
      []
    when "single"
      ["Policy: be concise and helpful."]
    when "multi"
      [
        "Policy: be concise and helpful.",
        "Guide: always cite sources when possible."
      ]
    else
      raise ArgumentError, "Unknown ctx_knowledge label: #{label}"
    end
  end

  def self.context_agent
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-18", version: 1
      model LM_STUDIO_MODEL
      provider :openai
      instructions "You are a helpful assistant."
    end
  end

  # ===========================================================================
  # GROUP 25 — BEFORE_LLM_INPUT HOOK
  # ===========================================================================

  # Returns a hook callable for the given bli_hook_return factor label.
  # The callable receives LLMInputBuildContext and returns LLMInputPatch or nil.
  def self.bli_hook_callable(return_label)
    case return_label
    when "nil"
      ->(_ctx) {}
    when "empty_hash"
      ->(_ctx) { Phronomy::Agent::LLMInputPatch.empty }
    when "param_merge"
      ->(_ctx) {
        Phronomy::Agent::LLMInputPatch.new(
          model_config_patch: {temperature: 0.1}
        )
      }
    when "model_override"
      ->(_ctx) {
        Phronomy::Agent::LLMInputPatch.new(
          model_config_patch: {model: LM_STUDIO_MODEL}
        )
      }
    else
      raise ArgumentError, "Unknown bli_hook_return label: #{return_label}"
    end
  end

  def self.bli_agent_class(label)
    case label
    when "base"
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-19", version: 1
        model LM_STUDIO_MODEL
        provider :openai
        instructions "You are a helpful assistant."
      end
    else
      raise ArgumentError, "Unknown bli_agent_class label: #{label}"
    end
  end

  def self.bli_build_agent(tier_label:, return_label:, klass:)
    callable = (tier_label == "none") ? nil : bli_hook_callable(return_label)

    case tier_label
    when "none"
      klass.new
    when "global"
      Phronomy.configuration.before_llm_input = callable
      klass.new
    when "class_level"
      klass.before_llm_input callable
      klass.new
    when "instance_level"
      instance = klass.new
      instance.before_llm_input = callable
      instance
    when "multi_tier"
      Phronomy.configuration.before_llm_input = callable
      klass.before_llm_input callable
      instance = klass.new
      instance.before_llm_input = callable
      instance
    else
      raise ArgumentError, "Unknown bli_hook_tier label: #{tier_label}"
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 26 — MULTI-AGENT HANDOFF helpers
  # ---------------------------------------------------------------------------
  LM_MODEL_26 = LM_STUDIO_MODEL

  def self.handoff_linear_classes
    entry_klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-20", version: 1
      model LM_MODEL_26
      provider :openai
      instructions "You are a triage assistant. Route billing questions to billing."
    end
    target_klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-21", version: 1
      model LM_MODEL_26
      provider :openai
      instructions "You are a billing assistant. Answer billing questions."
    end
    [entry_klass, target_klass]
  end

  def self.handoff_hub_spoke_instances(spoke_count: 2)
    spoke_klasses = (1..spoke_count).map do |i|
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-22", version: 1
        model LM_MODEL_26
        provider :openai
        instructions "You are spoke agent #{i}."
      end
    end

    hub_klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-23", version: 1
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
  LM_MODEL_27 = LM_STUDIO_MODEL

  def self.job_agent_class(label)
    case label
    when "base", "react"
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-24", version: 1
        model LM_MODEL_27
        provider :openai
        instructions "You are a helpful assistant."
      end
    else
      raise ArgumentError, "Unknown job_agent_type label: #{label}"
    end
  end

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

  def self.reset_state_store
    Phronomy.configure { |c| c.default_state_store = nil }
  end

  # ---------------------------------------------------------------------------
  # Group 29 — File State Store helpers
  # ---------------------------------------------------------------------------
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
  LM_MODEL_30 = LM_STUDIO_MODEL

  def self.approval_tool(result_value: "approval_tool_result")
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "approval_required_tool"
      description "A tool that requires approval"
      param :query, type: :string, desc: "Input for the tool"
      requires_approval true

      define_method(:execute) do |query:|
        result_value
      end
    end
  end

  def self.second_approval_tool(result_value: "second_approval_tool_result")
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "second_approval_required_tool"
      description "A second tool that requires approval"
      param :query, type: :string, desc: "Input for the tool"
      requires_approval true

      define_method(:execute) do |query:|
        result_value
      end
    end
  end

  def self.approval_resume_agent(*tool_classes)
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-25", version: 1
      model LM_MODEL_30
      provider :openai
      instructions "You are a helpful assistant. Use tools when asked."
      tools(tool_classes.to_h { |t| [t, nil] })
    end
  end

  # ---------------------------------------------------------------------------
  # GROUP 31 — SHARED STATE helpers
  # ---------------------------------------------------------------------------
  LM_MODEL_31 = LM_STUDIO_MODEL

  def self.ss_researcher_class
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-26", version: 1
      model LM_MODEL_31
      provider :openai
      instructions "You are a research assistant."
    end
  end

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

  def self.tc_worker_class(failing: false)
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-27", version: 1
      model LM_MODEL_32
      provider :openai
      context_window 32_768
      instructions "You are a worker agent."

      if failing
        define_method(:invoke) do |input, thread_id: nil, config: {}, **|
          raise "worker_error"
        end
      end
    end
  end

  def self.tc_team_class(pool_size:, on_error:, aggregate:, worker:)
    size = (pool_size == :single) ? 1 : 2
    err = on_error

    Class.new(Phronomy::MultiAgent::TeamCoordinator) do
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

  def self.gv_agent_class
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-28", version: 1
      model LM_MODEL_33
      provider :openai
    end
  end

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

  def self.gv_draft_response(confidence: 0.9)
    JSON.generate(
      answer: "The answer is 42.",
      confidence: confidence,
      citations: [{source: "policy.md", excerpt: "Key fact."}]
    )
  end

  def self.gv_review_response(approved: true)
    score = approved ? 0.85 : 0.3
    feedback = approved ? "" : "Missing citation for claim X."
    JSON.generate(approved: approved, score: score, feedback: feedback)
  end

  # ---------------------------------------------------------------------------
  # GROUP 34 — ORCHESTRATOR helpers
  # ---------------------------------------------------------------------------
  LM_MODEL_34 = LM_STUDIO_MODEL

  def self.orch_subagent_class
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-29", version: 1
      model LM_MODEL_34
      provider :openai
      instructions "You are a specialist subagent."
    end
  end

  def self.orch_declarative_class(subagent_count:, on_error:)
    sa1 = orch_subagent_class
    sa2 = orch_subagent_class
    err = on_error

    Class.new(Phronomy::MultiAgent::Orchestrator) do
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
  def self.vs_store(label)
    case label
    when "explicit" then Phronomy::VectorStore::InMemory.new(dimension: 2)
    when "inferred" then Phronomy::VectorStore::InMemory.new
    else raise ArgumentError, "Unknown vs_dimension_init label: #{label}"
    end
  end

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
  def self.bp_max_concurrency(label, task_count: 3)
    case label
    when "nil" then nil
    when "one" then 1
    when "gt_tasks" then task_count + 5
    else raise ArgumentError, "Unknown bp_max_concurrency label: #{label}"
    end
  end

  def self.bp_tasks(label)
    good = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-30", version: 1
      define_method(:invoke) { |input, config: {}, thread_id: nil| {output: "ok:#{input}", messages: []} }
      define_method(:invoke_async) do |input, **_kw|
        t = Phronomy::Task.new(name: "stub-async")
        Thread.new {
          begin
            t.complete(invoke(input))
          rescue
            t.fail($!)
          end
        }
        t
      end
    end
    bad = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-31", version: 1
      define_method(:invoke) { |*| raise "task_error" }
      define_method(:invoke_async) do |input, **_kw|
        t = Phronomy::Task.new(name: "stub-async")
        Thread.new {
          begin
            t.complete(invoke(input))
          rescue
            t.fail($!)
          end
        }
        t
      end
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

  def self.bp_orchestrator_class
    Class.new(Phronomy::MultiAgent::Orchestrator)
  end

  # ---------------------------------------------------------------------------
  # Group 37: BlockingAdapterPool boundary fixtures
  # ---------------------------------------------------------------------------
  class BbBlockingTool < Phronomy::Agent::Context::Capability::Base
    tool_name "bb_blocking_tool"
    description "A blocking_io tool used to verify pool routing"
    param :input, type: :string, desc: "Any string input"
    execution_mode :blocking_io

    def execute(input:)
      "blocking:#{input}"
    end
  end

  class BbCooperativeTool < Phronomy::Agent::Context::Capability::Base
    tool_name "bb_cooperative_tool"
    description "A cooperative tool used to verify it bypasses the pool"
    param :input, type: :string, desc: "Any string input"
    execution_mode :cooperative

    def execute(input:)
      "cooperative:#{input}"
    end
  end

  # ---------------------------------------------------------------------------
  # Group 38: :fiber backend cooperative runtime (Issue #339)
  # ---------------------------------------------------------------------------
  def self.fb_subject(label)
    case label
    when "spawn_await_value", "blocking_io_await", "async_queue_pop",
         "spawn_child", "error_propagation", "cancellation", "timer_real_clock",
         "agent_invoke_async", "llm_adapter_suspend", "mixed_tools",
         "rag_fetch", "stream_queue"
      label.to_sym
    else
      raise ArgumentError, "Unknown fb_subject label: #{label}"
    end
  end

  class FbBlockingTool < Phronomy::Agent::Context::Capability::Base
    tool_name "fb_blocking_tool"
    description "A blocking_io tool for fiber backend upper-layer tests"
    param :input, type: :string, desc: "Any string input"
    execution_mode :blocking_io

    def execute(input:)
      "blocking:#{input}"
    end
  end

  class FbCooperativeTool < Phronomy::Agent::Context::Capability::Base
    tool_name "fb_cooperative_tool"
    description "A cooperative tool for fiber backend upper-layer tests"
    param :input, type: :string, desc: "Any string input"
    execution_mode :cooperative

    def execute(input:)
      "cooperative:#{input}"
    end
  end
end
