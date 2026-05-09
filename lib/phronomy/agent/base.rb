# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    # Base class for all Phronomy agents.
    #
    # Subclass this to create a conversational agent powered by an LLM.
    # DSL class methods configure the model, instructions, tools, memory,
    # and retry behaviour. Instance methods handle invocation.
    #
    # @example Minimal agent
    #   class GreetingAgent < Phronomy::Agent::Base
    #     model "gpt-4o-mini"
    #     instructions "You are a friendly greeter."
    #   end
    #   result = GreetingAgent.new.invoke("Hello!")
    #   puts result[:output]
    #
    # @example Agent with tools
    #   class ResearchAgent < Phronomy::Agent::Base
    #     model "gpt-4o"
    #     instructions "You are a research assistant."
    #     tools WebSearchTool, CalculatorTool
    #     max_iterations 15
    #   end
    class Base
      include Phronomy::Runnable

      class << self
        # Sets or reads the LLM model identifier for this agent.
        # When called without an argument, returns the stored model or the
        # global default from {Phronomy.configuration}.
        #
        # @param name [String, nil] model identifier (e.g. "gpt-4o", "claude-3-5-sonnet")
        # @return [String, nil] the model name when used as a reader
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     model "gpt-4o"
        #   end
        def model(name = nil)
          if name
            @model = name
          else
            @model || Phronomy.configuration.default_model
          end
        end

        # Sets or reads the system instructions for this agent.
        # Accepts a String, a {Phronomy::PromptTemplate}, or a block (Proc).
        # When used as a reader (no argument, no block), returns the stored value.
        #
        # @param text [String, Phronomy::PromptTemplate, nil]
        # @yield optionally provide instructions as a block
        # @return [String, Phronomy::PromptTemplate, Proc, nil]
        # @example String instructions
        #   class MyAgent < Phronomy::Agent::Base
        #     instructions "You are a helpful assistant."
        #   end
        # @example Block instructions
        #   class MyAgent < Phronomy::Agent::Base
        #     instructions { |input| "Answer in #{input[:lang]}." }
        #   end
        def instructions(text = nil, &block)
          if text || block_given?
            @instructions = text || block
          else
            @instructions
          end
        end

        # Registers tool classes for this agent.
        #
        # Accepts either a splat of classes (backward-compatible) or a Hash mapping
        # each class to an explicit alias name (String) or nil (use tool's own name).
        # The alias form is useful when two tools share the same auto-generated name
        # (e.g. two SearchTool classes from different modules).
        #
        # @example Splat form (no alias)
        #   tools WeatherTool, TimeTool
        #
        # @example Hash form (with optional per-tool alias)
        #   tools(
        #     Weather::SearchTool => "weather_search",
        #     Places::SearchTool  => "places_search",
        #     CurrentTimeTool     => nil
        #   )
        def tools(*args)
          if args.empty?
            return @tools || []
          end

          if args.length == 1 && args.first.is_a?(Hash)
            hash = args.first
            @tools = hash.keys
            @tool_aliases = hash.transform_values { |v| v&.to_s }.reject { |_, v| v.nil? }
          else
            @tools = args
            @tool_aliases = {}
          end
        end

        # Returns the alias map registered via the hash form of .tools.
        # @return [Hash{Class => String}]
        def tool_aliases
          @tool_aliases ||= {}
        end

        # Sets or reads the LLM provider for this agent.
        # Required when using a model not registered in RubyLLM's model registry
        # (e.g. locally-hosted models via LM Studio or Ollama).
        #
        # @param name [Symbol, nil] e.g. +:openai+, +:anthropic+, +:ollama+
        # @return [Symbol, nil]
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     model "openai/gpt-oss-20b"
        #     provider :openai
        #   end
        def provider(name = nil)
          if name
            @provider = name
          else
            @provider
          end
        end

        # Sets or reads the sampling temperature sent to the LLM.
        # When nil, the provider's default is used.
        #
        # @param val [Float, nil] temperature (0.0 to 2.0 depending on provider)
        # @return [Float, nil]
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     temperature 0.2
        #   end
        def temperature(val = nil)
          if val
            @temperature = val
          else
            @temperature
          end
        end

        # Sets or reads the maximum number of LLM call cycles for ReAct agents.
        # Each tool call and follow-up counts as one iteration. Defaults to 10.
        #
        # @param val [Integer, nil]
        # @return [Integer]
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     max_iterations 5
        #   end
        def max_iterations(val = nil)
          if val
            @max_iterations = val
          else
            @max_iterations || 10
          end
        end

        # Configures a retry policy that wraps the full #invoke call.
        # GuardrailError is never retried regardless of this setting.
        #
        # @param times [Integer] maximum retry attempts (default: 0)
        # @param wait  [Symbol, Numeric] :exponential, :linear, or a fixed Float
        # @param base  [Float]  base wait time in seconds (default: 1.0)
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     retry_policy times: 2, wait: :exponential, base: 1.0
        #   end
        def retry_policy(times: 0, wait: 0, base: 1.0)
          @_retry_policy = {times: times, wait: wait, base: base}
        end

        # Returns the configured retry policy, or nil when none is set.
        # @return [Hash, nil]
        attr_reader :_retry_policy

        # Injectable sleep callable for testing (shared with Tool::Base pattern).
        # @return [#call]
        def _sleep_proc
          @_sleep_proc || method(:sleep)
        end

        # Overrides the sleep callable used between retries.
        # @param proc [#call]
        attr_writer :_sleep_proc

        # Registers one or more static knowledge sources on the agent class.
        # Static sources are fetched once per agent instance and their content
        # is cached in ContextVersionCache keyed by a fingerprint of the
        # instruction text + source content. The cache is invalidated automatically
        # when the fingerprint changes (e.g. because a source was updated).
        #
        # @param sources [Array<Phronomy::KnowledgeSource::Base>]
        # @example
        #   class PolicyAgent < Phronomy::Agent::Base
        #     static_knowledge Phronomy::KnowledgeSource::StaticKnowledge.new(POLICY_TEXT)
        #   end
        def static_knowledge(*sources)
          @static_knowledge_sources = sources.flatten
        end

        # Returns the registered static knowledge sources.
        # @return [Array<Phronomy::KnowledgeSource::Base>]
        def static_knowledge_sources
          @static_knowledge_sources || []
        end

        # Registers a callback that is invoked before every LLM call so the
        # application can remove stale or irrelevant messages from the
        # conversation history.
        #
        # The block receives a {Phronomy::Context::TrimContext} and may call
        # +ctx.remove(seqs)+ to drop messages by seq number. Changes affect
        # only the current invocation; the underlying memory store is unchanged.
        #
        # @yield [ctx] Phronomy::Context::TrimContext
        # @example Drop the oldest message when over 80% of budget is used
        #   on_trim do |ctx|
        #     limit = ctx.budget&.available(used: 0) || Float::INFINITY
        #     ctx.remove(ctx.message_elements.first[:seq]) if ctx.total_tokens > limit * 0.8
        #   end
        def on_trim(&block)
          @on_trim_callback = block
        end

        # @return [Proc, nil]
        def _on_trim_callback
          @on_trim_callback
        end

        # Registers a callback that decides whether compaction should run.
        # Evaluated before every LLM call (after on_trim). If the block returns
        # truthy AND an +on_compact+ callback is also registered, the compact
        # pipeline is executed.
        #
        # The block receives a read-only {Phronomy::Context::TriggerContext}.
        #
        # @yield [ctx] Phronomy::Context::TriggerContext
        # @return [Boolean] truthy → run on_compact; falsy → skip
        # @example Trigger when messages exceed 70% of token budget
        #   on_compaction_trigger do |ctx|
        #     limit = ctx.budget&.available(used: 0) || Float::INFINITY
        #     ctx.total_tokens > limit * 0.7
        #   end
        def on_compaction_trigger(&block)
          @on_compaction_trigger_callback = block
        end

        # @return [Proc, nil]
        def _on_compaction_trigger_callback
          @on_compaction_trigger_callback
        end

        # Registers a callback that performs the actual compaction when the
        # +on_compaction_trigger+ callback fires. The block receives a
        # {Phronomy::Context::CompactionContext} and should call +ctx.compact+
        # to specify which messages to summarise.
        #
        # @yield [ctx] Phronomy::Context::CompactionContext
        # @example Replace the first 4 messages with a short summary
        #   on_compact do |ctx|
        #     ctx.compact(0..3) do |elements|
        #       texts = elements.map { |e| e[:message].content }.join(" | ")
        #       "Earlier conversation summary: #{texts}"
        #     end
        #   end
        def on_compact(&block)
          @on_compact_callback = block
        end

        # @return [Proc, nil]
        def _on_compact_callback
          @on_compact_callback
        end

        # When enabled, attaches Anthropic prompt-cache markers to the system
        # message so that the fixed instructions are served from cache on
        # subsequent turns, reducing input-token costs.
        #
        # Only has an effect when the agent also declares `provider :anthropic`.
        # The cache_control field is provider-specific (the format differs
        # between Anthropic direct, Bedrock, etc.), so the agent must explicitly
        # declare its provider via the DSL rather than having it inferred from
        # the model name.
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     provider :anthropic
        #     cache_instructions true
        #   end
        def cache_instructions(enabled = nil)
          if enabled.nil?
            @cache_instructions
          else
            @cache_instructions = enabled
          end
        end

        # Tokens to reserve for the model's output.
        # When nil, the model's max_output_tokens from the registry is used.
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     max_output_tokens 4096
        #   end
        def max_output_tokens(val = nil)
          if val.nil?
            @max_output_tokens
          else
            @max_output_tokens = val.to_i
          end
        end

        # Overrides the context window size used for token budget calculations.
        # When set, this value takes precedence over the RubyLLM model registry,
        # which is useful for locally-hosted models (e.g. LM Studio) where the
        # actually-loaded context length may differ from the catalogue value.
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     context_window 4096
        #   end
        def context_window(val = nil)
          if val.nil?
            @context_window
          else
            @context_window = val.to_i
          end
        end

        # Tokens reserved for the system prompt + tool definitions overhead.
        # Subtract this from the context window before computing the memory budget.
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     context_overhead 500
        #   end
        def context_overhead(val = nil)
          if val.nil?
            @context_overhead || 0
          else
            @context_overhead = val.to_i
          end
        end
      end

      # Invokes the agent with the given input and returns a result Hash.
      # Applies the retry policy configured via {.retry_policy} when transient
      # errors occur. {Phronomy::GuardrailError} is never retried.
      #
      # @param input  [String, Hash] the user message; a Hash may supply
      #   +:message+, +:query+, or +:user+ as the text key, plus any template
      #   variables consumed by the configured instructions template.
      # @param config [Hash] runtime options:
      #   +:memory+    ({Phronomy::Memory::ConversationManager}) — memory backend
      #   +:thread_id+ (+String+)                 — conversation thread identifier
      # @return [Hash] +{ output: String, messages: Array, usage: Phronomy::TokenUsage }+
      # @raise [Phronomy::GuardrailError] when an input or output guardrail rejects the value
      # @example
      #   result = MyAgent.new.invoke("What is Ruby?")
      #   puts result[:output]
      def invoke(input, config: {})
        policy = self.class._retry_policy
        attempt = 0
        begin
          invoke_once(input, config: config)
        rescue Phronomy::GuardrailError
          raise
        rescue
          if policy && attempt < policy[:times]
            wait = compute_agent_retry_wait(policy[:wait], policy[:base], attempt)
            self.class._sleep_proc.call(wait) if wait > 0
            attempt += 1
            retry
          end
          raise
        end
      end

      # Streaming version of #invoke. Yields {Phronomy::Agent::StreamEvent} objects
      # as they are produced by the underlying LLM.
      #
      # Events emitted (in order):
      #   :token       — each content delta from the LLM
      #   :tool_call   — when the LLM requests a tool (ReactAgent subclasses only)
      #   :tool_result — after a tool completes (ReactAgent subclasses only)
      #   :done        — final event carrying output, messages, and usage
      #   :error       — if an unrecoverable error occurs
      #
      # @param input  [String, Hash] same as #invoke
      # @param config [Hash]        same as #invoke
      # @yield [Phronomy::Agent::StreamEvent]
      # @return [Hash] { output:, messages:, usage: } — same as #invoke
      def stream(input, config: {}, &block)
        return invoke(input, config: config) unless block

        run_input_guardrails!(input)

        memory = config[:memory]
        thread_id = config[:thread_id]

        chat = build_chat
        user_message = extract_message(input)

        # Assemble context via Assembler (same as invoke_once).
        assembler = Context::Assembler.new(budget: build_token_budget)
        system_msg = build_instructions(input)
        assembler.add_instruction(system_msg) if system_msg

        Array(config[:knowledge_sources]).each do |ks|
          ks.fetch(query: user_message).each do |chunk|
            assembler.add_knowledge(chunk[:content], type: chunk[:type])
          end
        end

        if memory && thread_id
          msgs = load_from_memory(memory, thread_id: thread_id, query: user_message)
          assembler.add_messages(msgs)
        end

        context = assembler.build
        apply_instructions(chat, context[:system]) if context[:system]
        context[:messages].each { |msg| chat.messages << msg }

        # Wire per-event callbacks to yield StreamEvents.
        chat.on_tool_call { |tool_call| block.call(StreamEvent.new(type: :tool_call, payload: {tool_call: tool_call})) }
        chat.on_tool_result { |tool_result| block.call(StreamEvent.new(type: :tool_result, payload: {tool_result: tool_result})) }

        response = chat.ask(user_message) do |chunk|
          block.call(StreamEvent.new(type: :token, payload: {content: chunk.content}))
        end

        save_to_memory(memory, thread_id: thread_id, messages: chat.messages) if memory && thread_id

        output = response.content
        usage = Phronomy::TokenUsage.from_tokens(response.tokens)

        run_output_guardrails!(output)

        result = {output: output, messages: chat.messages, usage: usage}
        block.call(StreamEvent.new(type: :done, payload: result))
        result
      rescue => e
        block&.call(StreamEvent.new(type: :error, payload: {error: e}))
        raise
      end

      # Registers a callback that is invoked before executing any tool that has
      # +requires_approval true+ set. The block receives the tool name (String)
      # and the arguments Hash, and must return a truthy value to allow execution.
      # Returning a falsy value causes the tool to return a denial message instead
      # of executing.
      #
      # When no handler is registered, tools with +requires_approval+ execute
      # without interruption (backward-compatible behaviour).
      #
      # @example
      #   agent = MyAgent.new
      #   agent.on_approval_required { |tool_name, args| prompt_user(tool_name, args) }
      # @return [self]
      def on_approval_required(&block)
        @approval_handler = block
        self
      end

      # Attach a guardrail that validates input before every #invoke call.
      # @param guardrail [Phronomy::Guardrail::InputGuardrail]
      def add_input_guardrail(guardrail)
        @input_guardrails ||= []
        @input_guardrails << guardrail
        self
      end

      # Attach a guardrail that validates output before it is returned.
      # @param guardrail [Phronomy::Guardrail::OutputGuardrail]
      def add_output_guardrail(guardrail)
        @output_guardrails ||= []
        @output_guardrails << guardrail
        self
      end

      private

      # Performs a single (non-retried) invocation. Extracted so that #invoke can
      # wrap it in a retry loop without duplicating the LLM interaction logic.
      def invoke_once(input, config: {})
        # Run input guardrails before touching the LLM.
        run_input_guardrails!(input)

        memory = config[:memory]
        thread_id = config[:thread_id]
        user_message = extract_message(input)
        chat = build_chat
        budget = build_token_budget

        # Load conversation history from memory.
        raw_messages = (memory && thread_id) ?
          load_from_memory(memory, thread_id: thread_id, query: user_message) : []

        # Assign synthetic 0-based seq numbers for use by trim/compaction callbacks.
        message_elements = build_message_elements(raw_messages)

        # Run on_trim: app may call ctx.remove(seqs) to drop messages this turn.
        if (trim_cb = self.class._on_trim_callback)
          trim_ctx = Context::TrimContext.new(message_elements: message_elements, budget: budget)
          trim_cb.call(trim_ctx)
          message_elements = trim_ctx.message_elements
        end

        # Run on_compaction_trigger → on_compact pipeline before calling the LLM.
        if (trigger_cb = self.class._on_compaction_trigger_callback)
          trigger_ctx = Context::TriggerContext.new(
            message_elements: message_elements, budget: budget
          )
          if trigger_cb.call(trigger_ctx)
            if (compact_cb = self.class._on_compact_callback)
              compact_ctx = Context::CompactionContext.new(
                message_elements: message_elements,
                budget: budget,
                thread_id: thread_id,
                memory: memory
              )
              compact_cb.call(compact_ctx)
              message_elements = build_message_elements(compact_ctx.result_messages)
            end
          end
        end

        # Build the system prompt via the fingerprint-keyed ContextVersionCache.
        # Static knowledge is fetched and concatenated once; the result is reused
        # on subsequent calls as long as the fingerprint remains valid.
        system_text = build_cached_system_text(input)

        # Assemble context regions 1 (Instruction+Static Knowledge) + 3 (Dynamic Knowledge)
        # + 4 (Conversation).
        assembler = Context::Assembler.new(budget: budget)
        assembler.add_instruction(system_text) if system_text

        # Dynamic knowledge from config[:knowledge_sources] (backward compatible).
        Array(config[:knowledge_sources]).each do |ks|
          ks.fetch(query: user_message).each do |chunk|
            assembler.add_knowledge(chunk[:content], type: chunk[:type])
          end
        end

        assembler.add_messages(message_elements.map { |e| e[:message] })

        context = assembler.build
        apply_instructions(chat, context[:system]) if context[:system]
        context[:messages].each { |msg| chat.messages << msg }

        response = chat.ask(user_message)

        # Persist the updated conversation to memory.
        save_to_memory(memory, thread_id: thread_id, messages: chat.messages) if memory && thread_id

        output = response.content
        usage = Phronomy::TokenUsage.from_tokens(response.tokens)

        # Run output guardrails before returning to the caller.
        run_output_guardrails!(output)

        {output: output, messages: chat.messages, usage: usage}
      end

      # Computes the agent-level retry wait duration.
      # @param strategy [Symbol, Numeric]
      # @param base     [Float]
      # @param attempt  [Integer]
      # @return [Float]
      def compute_agent_retry_wait(strategy, base, attempt)
        case strategy
        when :exponential
          (2**attempt) * base
        when :linear
          (attempt + 1) * base
        when Numeric
          strategy.to_f
        else
          base.to_f
        end
      end

      # Builds a TokenBudget for this agent's model if possible.
      # When context_window is set at the class level, that value is used directly
      # (bypassing the RubyLLM catalogue) — useful for locally-hosted models where
      # the loaded context length differs from the catalogue value.
      # Returns nil when the model is not registered in RubyLLM (e.g. local/unknown models).
      def build_token_budget
        model_name = self.class.model
        return nil unless model_name

        if (cw = self.class.context_window)
          Phronomy::Context::TokenBudget.new(
            context_window: cw,
            max_output_tokens: self.class.max_output_tokens || 0,
            overhead: self.class.context_overhead
          )
        else
          Phronomy::Context::TokenBudget.new(
            model: model_name,
            max_output_tokens: self.class.max_output_tokens,
            overhead: self.class.context_overhead
          )
        end
      rescue Phronomy::Context::UnknownModelError, RubyLLM::ModelNotFoundError
        nil
      end

      # Converts a flat Array of message objects into the internal message_elements
      # format used by TrimContext, TriggerContext, and CompactionContext.
      # Each element receives a 0-based synthetic seq number.
      #
      # @param messages [Array] message-like objects with #role and #content
      # @return [Array<Hash>]
      def build_message_elements(messages)
        Array(messages).each_with_index.map do |msg, idx|
          tokens = Context::TokenEstimator.estimate(msg.content.to_s)
          {seq: idx, message: msg, tokens: tokens, role: msg.role}
        end
      end

      # Builds (or returns a cached) system prompt text.
      # The fingerprint is a SHA-256 digest of the instruction text concatenated
      # with the content of every registered static knowledge source.
      # When the fingerprint is unchanged the ContextVersionCache returns the
      # previously assembled text without re-fetching any sources.
      #
      # @param input [String, Hash] the agent's current input (used for template evaluation)
      # @return [String, nil] assembled system text, or nil when empty
      def build_cached_system_text(input)
        instruction = build_instructions(input)

        static_chunks = self.class.static_knowledge_sources.flat_map { |ks|
          ks.fetch(query: nil)
        }

        fingerprint = Digest::SHA256.hexdigest(
          [instruction.to_s, *static_chunks.map { |c| c[:content] }].join("\0")
        )

        cache = (@_context_version_cache ||= Context::ContextVersionCache.new)
        unless cache.valid?(fingerprint)
          parts = [instruction]
          static_chunks.each do |chunk|
            parts << Context::Assembler.xml_tag(chunk[:content], type: chunk[:type], trusted: true)
          end
          cache.update(fingerprint: fingerprint, system_text: parts.compact.join("\n\n"))
        end

        cache.system_text.empty? ? nil : cache.system_text
      end

      # Load messages from a ConversationManager.
      #
      # @param memory    [Memory::ConversationManager]
      # @param thread_id [String]
      # @param query     [String, nil]
      # @return [Array]
      def load_from_memory(memory, thread_id:, query: nil)
        memory.load(thread_id: thread_id, query: query)
      end

      # Persist messages to a ConversationManager.
      #
      # @param memory    [Memory::ConversationManager]
      # @param thread_id [String]
      # @param messages  [Array]
      def save_to_memory(memory, thread_id:, messages:)
        memory.save(thread_id: thread_id, messages: messages)
      end

      def build_chat
        opts = {}
        m = self.class.model
        opts[:model] = m if m
        p = self.class.provider
        if p
          opts[:provider] = p
          opts[:assume_model_exists] = true
        end
        t = self.class.temperature
        chat = RubyLLM.chat(**opts)
        chat.with_temperature(t) if t
        self.class.tools.each do |tool_class|
          chat.with_tool(prepare_tool_class(tool_class))
        end
        chat
      end

      def build_instructions(input)
        instr = self.class.instructions
        case instr
        when Phronomy::PromptTemplate
          vars = input.is_a?(Hash) ? input : {input: input}
          instr.format_system(**vars) || instr.format(**vars)
        when String then instr
        when Proc then instr.call(input)
        when nil then nil
        end
      end

      # Applies system instructions to a chat object.
      # When cache_instructions is enabled and the provider is Anthropic,
      # attaches a cache_control marker so that the fixed system prompt is
      # eligible for prompt caching.
      def apply_instructions(chat, text)
        if self.class.cache_instructions && anthropic_provider?
          content = RubyLLM::Providers::Anthropic::Content.new(text, cache: true)
          chat.with_instructions(content)
        else
          chat.with_instructions(text)
        end
      end

      # Returns true when this agent explicitly declares `provider :anthropic`.
      # Provider is intentionally checked via the DSL value rather than inferred
      # from the model name, because cache_control format is API-endpoint-specific
      # (Anthropic direct vs. Bedrock vs. OpenRouter all differ).
      def anthropic_provider?
        self.class.provider == :anthropic
      end

      def extract_message(input)
        case input
        when String then input
        when Hash then input[:message] || input[:query] || input[:user] || input.to_s
        else input.to_s
        end
      end

      def run_input_guardrails!(input)
        (@input_guardrails || []).each { |g| g.run!(input) }
      end

      def run_output_guardrails!(output)
        (@output_guardrails || []).each { |g| g.run!(output) }
      end

      # Builds the final tool class to register with the chat.
      #
      # Two transformations are applied in order:
      #   1. Alias override — when the Hash form of .tools maps this class to an
      #      explicit name, an anonymous subclass with that tool_name is returned.
      #   2. Approval gate  — when the tool class has +requires_approval+ set AND
      #      an approval handler has been registered via #on_approval_required,
      #      the tool's #call method is wrapped: the handler is invoked with
      #      (tool_name, args) and, if it returns falsy, the tool returns a denial
      #      message instead of executing.
      def prepare_tool_class(tool_class)
        # Step 1: apply alias if needed.
        resolved = if (alias_name = self.class.tool_aliases[tool_class])
          parent_description = tool_class.description
          Class.new(tool_class) do
            tool_name alias_name
            description parent_description if parent_description
          end
        else
          tool_class
        end

        # Step 2: wrap with approval gate when handler is registered.
        return resolved unless resolved.requires_approval && @approval_handler

        handler = @approval_handler
        # Capture the effective tool name before building the anonymous subclass.
        # Class-level instance variables (@tool_name) are not inherited through
        # subclassing, so the wrapper must set it explicitly.
        effective_name = resolved.new.name
        Class.new(resolved) do
          tool_name effective_name
          define_method(:call) do |args|
            if handler.call(name, args)
              super(args)
            else
              "Tool execution denied."
            end
          end
        end
      end
    end
  end
end
