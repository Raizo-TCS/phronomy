# frozen_string_literal: true

require "digest"
require_relative "concerns/retryable"
require_relative "concerns/guardrailable"
require_relative "concerns/before_completion"
require_relative "concerns/suspendable"

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
      include Concerns::Retryable
      include Concerns::Guardrailable
      include Concerns::BeforeCompletion
      include Concerns::Suspendable

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
            return @instructions if instance_variable_defined?(:@instructions)
            superclass.respond_to?(:instructions) ? superclass.instructions : nil
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
            if instance_variable_defined?(:@tools)
              return @tools
            end
            return superclass.respond_to?(:tools) ? superclass.tools : []
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
            return @provider if instance_variable_defined?(:@provider)
            superclass.respond_to?(:provider) ? superclass.provider : nil
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

      # Registers an anonymous handoff tool class on this agent instance.
      # Called by Runner during construction when routes are configured.
      # @param tool_class [Class<Phronomy::Tool::Base>]
      # @return [self]
      def _add_handoff_tool(tool_class)
        @_handoff_tools ||= []
        @_handoff_tools << tool_class
        self
      end

      # Returns handoff tool classes registered on this instance by Runner.
      # @return [Array<Class>]
      def _handoff_tools
        @_handoff_tools || []
      end

      # Invokes the agent with the given input and returns a result Hash.
      # Applies the retry policy configured via {.retry_policy} when transient
      # errors occur. {Phronomy::GuardrailError} is never retried.
      #
      # @param input  [String, Hash] the user message; a Hash may supply
      #   +:message+, +:query+, or +:user+ as the text key, plus any template
      #   variables consumed by the configured instructions template.
      # @param config [Hash] runtime options:
      #   +:messages+   (Array<RubyLLM::Message>)  — conversation history from a previous invocation
      #   +:thread_id+  (+String+)                 — conversation thread identifier
      #   +:user_id+    (+String+, optional)        — caller identity forwarded to the tracer
      #   +:session_id+ (+String+, optional)        — session identity forwarded to the tracer
      # @return [Hash] +{ output: String, messages: Array, usage: Phronomy::TokenUsage }+,
      #   or +{ output: nil, suspended: true, checkpoint: Phronomy::Agent::Checkpoint,
      #   messages: Array }+ when the invocation was suspended awaiting tool approval.
      # @raise [Phronomy::GuardrailError] when an input or output guardrail rejects the value
      # @example Normal invocation
      #   result = MyAgent.new.invoke("What is Ruby?")
      #   puts result[:output]
      # @example Suspend / resume flow
      #   result = agent.invoke("Perform task X")
      #   if result[:suspended]
      #     result = agent.resume(result[:checkpoint], approved: true)
      #   end
      #   puts result[:output]
      def invoke(input, config: {})
        _invoke_impl(input, config: config)
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

        _stream_impl(input, config: config, &block)
      rescue => e
        block&.call(StreamEvent.new(type: :error, payload: {error: e}))
        raise
      end

      # Returns the {Context::ContextVersionCache} for the current thread.
      # @api private
      def context_version_cache
        (Thread.current[:phronomy_context_version_caches] ||= {})[object_id]
      end

      private

      # Streaming implementation for #stream.
      def _stream_impl(input, config: {}, &block)
        caller_meta = {}
        caller_meta[:user_id] = config[:user_id] if config[:user_id]
        caller_meta[:session_id] = config[:session_id] if config[:session_id]

        trace("agent.invoke", input: input, **caller_meta) do |_span|
          run_input_guardrails!(input)

          chat = build_chat
          user_message = extract_message(input)

          # Assemble context (system prompt + history). Override #build_context to
          # inject custom context editing logic at the Agent subclass level.
          context = build_context(input, config: config)
          apply_instructions(chat, context[:system]) if context[:system]
          context[:messages].each { |msg| chat.messages << msg }

          # Wire per-event callbacks to yield StreamEvents.
          current_tool_call = nil
          chat.on_tool_call do |tool_call|
            current_tool_call = tool_call
            block.call(StreamEvent.new(type: :tool_call, payload: {tool_call: tool_call}))
          end
          chat.on_tool_result do |tool_result|
            block.call(StreamEvent.new(type: :tool_result, payload: {
              tool_call_id: current_tool_call&.id,
              tool_name: current_tool_call&.name,
              tool_result: tool_result
            }))
          end

          # Run before_completion hooks (global → class → instance) before the LLM call.
          run_before_completion_hooks!(chat, config)

          response = chat.ask(user_message) do |chunk|
            block.call(StreamEvent.new(type: :token, payload: {content: chunk.content}))
          end

          output = response.content
          usage = Phronomy::TokenUsage.from_tokens(response.tokens)

          run_output_guardrails!(output)

          result = {output: output, messages: chat.messages, usage: usage}
          block.call(StreamEvent.new(type: :done, payload: result))
          [result, usage]
        end
      end

      # Assembles the LLM context (system prompt + conversation messages)
      # for a single invocation. Subclasses may override this method to
      # inject custom context editing logic without having to override
      # the full #invoke_once pipeline.
      #
      # @param input  [String, Hash] the user's input for this turn
      # @param config [Hash] the invocation config (see #invoke)
      # @return [Hash] { system: String|nil, messages: Array }
      def build_context(input, config: {})
        messages = prepare_history(config)
        budget = build_token_budget
        system_text = build_cached_system_text(input)
        user_message = extract_message(input)

        assembler = Context::Assembler.new(budget: budget)
        assembler.add_instruction(system_text) if system_text

        Array(config[:knowledge_sources]).each do |ks|
          ks.fetch(query: user_message).each do |chunk|
            assembler.add_knowledge(chunk[:content], type: chunk[:type], source: chunk[:source])
          end
        end

        assembler.add_messages(messages)
        assembler.build
      end
      protected :build_context

      # Loads app-managed conversation history from config[:messages] and
      # runs the on_trim / on_compaction_trigger / on_compact pipeline.
      # Returns the final Array of message objects ready to pass to the Assembler.
      #
      # Override this method in a subclass to customize how conversation
      # history is filtered or compressed before context assembly.
      #
      # @param config [Hash] the invocation config hash
      # @return [Array] filtered and/or compacted message objects
      def prepare_history(config)
        thread_id = config[:thread_id]
        budget = build_token_budget
        elements = build_message_elements(Array(config[:messages]))

        if (trim_cb = self.class._on_trim_callback)
          trim_ctx = Context::TrimContext.new(message_elements: elements, budget: budget)
          trim_cb.call(trim_ctx)
          elements = trim_ctx.message_elements
        end

        if (trigger_cb = self.class._on_compaction_trigger_callback)
          trigger_ctx = Context::TriggerContext.new(message_elements: elements, budget: budget)
          if trigger_cb.call(trigger_ctx)
            if (compact_cb = self.class._on_compact_callback)
              compact_ctx = Context::CompactionContext.new(
                message_elements: elements,
                budget: budget,
                thread_id: thread_id
              )
              compact_cb.call(compact_ctx)
              elements = build_message_elements(compact_ctx.result_messages)
            end
          end
        end

        elements.map { |e| e[:message] }
      end
      protected :prepare_history

      # Performs a single (non-retried) invocation. Extracted so that #invoke can
      # wrap it in a retry loop without duplicating the LLM interaction logic.
      def invoke_once(input, config: {})
        caller_meta = {}
        caller_meta[:user_id] = config[:user_id] if config[:user_id]
        caller_meta[:session_id] = config[:session_id] if config[:session_id]

        trace("agent.invoke", input: input, **caller_meta) do |_span|
          # Run input guardrails before touching the LLM.
          run_input_guardrails!(input)

          thread_id = config[:thread_id]
          user_message = extract_message(input)
          chat = build_chat

          # Assemble context (system prompt + history). Override #build_context to
          # inject custom context editing logic at the Agent subclass level.
          context = build_context(input, config: config)
          apply_instructions(chat, context[:system]) if context[:system]
          context[:messages].each { |msg| chat.messages << msg }

          # Run before_completion hooks (global → class → instance) before the LLM call.
          run_before_completion_hooks!(chat, config)

          # Register suspension hook for approval-required tools (no-op when a
          # synchronous on_approval_required handler is already registered).
          _register_suspension_hook!(chat)

          begin
            response = chat.ask(user_message)
          rescue SuspendSignal => signal
            checkpoint = Checkpoint.new(
              thread_id: thread_id,
              messages: chat.messages.dup,
              pending_tool_name: signal.tool_name,
              pending_tool_args: signal.args,
              pending_tool_call_id: signal.tool_call_id
            )
            suspended_result = {output: nil, suspended: true, checkpoint: checkpoint, messages: chat.messages}
            next [suspended_result, nil]
          end

          output = response.content
          usage = Phronomy::TokenUsage.from_tokens(response.tokens)

          # Run output guardrails before returning to the caller.
          run_output_guardrails!(output)

          result = {output: output, messages: chat.messages, usage: usage}
          [result, usage]
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

        agent_id = object_id
        cache = (Thread.current[:phronomy_context_version_caches] ||= {})[agent_id] ||=
          Context::ContextVersionCache.new
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
        _handoff_tools.each { |tc| chat.with_tool(tc) }
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
