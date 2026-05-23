# frozen_string_literal: true

require "digest"
require "securerandom"
require "timeout"
require_relative "concerns/retryable"
require_relative "concerns/guardrailable"
require_relative "concerns/before_completion"
require_relative "concerns/suspendable"
require_relative "concerns/error_translation"

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
      include Concerns::ErrorTranslation

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
        # @api public
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
        # @api public
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
        # @api public
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
        # Merges parent class aliases so subclasses inherit their parent's mappings.
        # Subclass-specific aliases take precedence over parent aliases.
        # @return [Hash{Class => String}]
        # @api public
        def tool_aliases
          own = @tool_aliases || {}
          if superclass.respond_to?(:tool_aliases)
            superclass.tool_aliases.merge(own)
          else
            own
          end
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
        # @api public
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
        # @api public
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
        # @api public
        def max_iterations(val = nil)
          if val
            @max_iterations = val
          else
            @max_iterations || 10
          end
        end

        # Sets or reads the maximum number of tool calls executed concurrently
        # when the LLM returns multiple tool calls in a single response
        # (ParallelToolChat mode, active inside an AgentFSM IO thread).
        #
        # Defaults to 10. Set to 1 to force sequential execution.
        # Inherited by subclasses; the most-specific definition wins.
        #
        # @param val [Integer, nil]
        # @return [Integer]
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     max_parallel_tools 4
        #   end
        # @api public
        def max_parallel_tools(val = nil)
          if val.nil?
            @max_parallel_tools ||
              (superclass.respond_to?(:max_parallel_tools) ? superclass.max_parallel_tools : 10)
          else
            unless val.is_a?(Integer) && val >= 1
              raise ArgumentError,
                "max_parallel_tools must be a positive Integer (>= 1), got #{val.inspect}"
            end
            @max_parallel_tools = val
          end
        end

        # Sets or reads the per-invocation timeout (in seconds) for EventLoop-mode
        # agent calls.  When set, +invoke+ raises {Phronomy::TimeoutError} if the
        # agent does not finish within the given number of seconds.
        #
        # Has no effect when EventLoop mode is disabled (direct invoke path).
        # Defaults to +nil+ (no timeout).
        # Inherited by subclasses; the most-specific definition wins.
        #
        # **Note**: +invoke_timeout+ is a *wait timeout*, not a cancellation.
        # When the timeout fires, +Phronomy::TimeoutError+ is raised to the
        # caller, but the background agent thread and any in-flight LLM or tool
        # calls are **not** interrupted — they continue running until they
        # complete naturally.  The agent therefore keeps consuming threads,
        # memory, and external API credits after the caller has already received
        # the error.  True cancellation is not yet supported.
        #
        # @param val [Numeric, nil]
        # @return [Numeric, nil]
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     invoke_timeout 30
        #   end
        # @api public
        def invoke_timeout(val = nil)
          if val.nil?
            return @invoke_timeout if defined?(@invoke_timeout)
            superclass.respond_to?(:invoke_timeout) ? superclass.invoke_timeout : nil
          else
            unless val.is_a?(Numeric) && val > 0
              raise ArgumentError,
                "invoke_timeout must be a positive number, got #{val.inspect}"
            end
            @invoke_timeout = val
          end
        end

        # Registers one or more static knowledge sources on the agent class.
        # Static source content is fetched and memoized at the **class** level
        # the first time +invoke+ is called. The cache persists for the lifetime
        # of the process; call {.static_knowledge_refresh!} to force a reload.
        #
        # @param sources [Array<Phronomy::KnowledgeSource::Base>]
        # @example
        #   class PolicyAgent < Phronomy::Agent::Base
        #     static_knowledge Phronomy::KnowledgeSource::StaticKnowledge.new(POLICY_TEXT)
        #   end
        # @api public
        def static_knowledge(*sources)
          @static_knowledge_sources = sources.flatten
          # Invalidate the cached chunks so the new sources are fetched on
          # the next call to static_knowledge_chunks.
          @static_knowledge_chunks = nil
        end

        # Returns the registered static knowledge sources.
        # @return [Array<Phronomy::KnowledgeSource::Base>]
        # @api public
        def static_knowledge_sources
          @static_knowledge_sources || []
        end

        # Returns the fetched content from all static knowledge sources.
        # Results are cached at the class level so that each source is fetched
        # only once regardless of how many times the agent is invoked.
        # @return [Array<Hash>]
        # @api public
        def static_knowledge_chunks
          @static_knowledge_chunks ||= static_knowledge_sources.flat_map { |ks|
            ks.fetch(query: nil)
          }
        end

        # Clears the class-level knowledge cache so that the next +invoke+ call
        # re-fetches content from all registered static knowledge sources.
        #
        # Call this method when the underlying knowledge source has been updated
        # at runtime (e.g. a file was rewritten, a DB record changed) and you
        # want the agent to pick up the new content without restarting the
        # process.
        #
        # @return [nil]
        # @example Refresh after updating a knowledge file
        #   MyAgent.static_knowledge_refresh!
        # @api public
        def static_knowledge_refresh!
          @static_knowledge_chunks = nil
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
        # @api public
        def on_trim(&block)
          @on_trim_callback = block
        end

        # @return [Proc, nil]
        # @api private
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
        # @api public
        def on_compaction_trigger(&block)
          @on_compaction_trigger_callback = block
        end

        # @return [Proc, nil]
        # @api private
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
        # @api public
        def on_compact(&block)
          @on_compact_callback = block
        end

        # @return [Proc, nil]
        # @api private
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
        # @api public
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
        # @api public
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
        # @api public
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
        # @api public
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
      # @api private
      def _add_handoff_tool(tool_class)
        @_handoff_tools ||= []
        @_handoff_tools << tool_class
        self
      end

      # Returns handoff tool classes registered on this instance by Runner.
      # @return [Array<Class>]
      # @api private
      def _handoff_tools
        @_handoff_tools || []
      end

      # Invokes the agent with the given input and returns a result Hash.
      # Applies the retry policy configured via {.retry_policy} when transient
      # errors occur. {Phronomy::GuardrailError} is never retried.
      #
      # @param input     [String, Hash] the user message; a Hash may supply
      #   +:message+, +:query+, or +:user+ as the text key, plus any template
      #   variables consumed by the configured instructions template.
      # @param messages  [Array<RubyLLM::Message>] conversation history from a
      #   previous invocation. The application owns and persists this array;
      #   pass it on every turn to maintain multi-turn context.
      # @param thread_id [String, nil] conversation thread identifier, forwarded
      #   to the compaction context when on_compact is configured.
      # @param config    [Hash] additional runtime options:
      #   +:knowledge_sources+ (Array) — dynamic knowledge sources for this turn
      #   +:user_id+    (+String+, optional) — caller identity forwarded to the tracer
      #   +:session_id+ (+String+, optional) — session identity forwarded to the tracer
      # @return [Hash] +{ output: String, messages: Array, usage: Phronomy::TokenUsage }+,
      #   or +{ output: nil, suspended: true, checkpoint: Phronomy::Agent::Checkpoint,
      #   messages: Array }+ when the invocation was suspended awaiting tool approval.
      # @raise [Phronomy::GuardrailError] when an input or output guardrail rejects the value
      # @example Normal invocation
      #   result = MyAgent.new.invoke("What is Ruby?")
      #   puts result[:output]
      # @example Multi-turn conversation
      #   result1 = agent.invoke("Hi, I'm Alice.")
      #   result2 = agent.invoke("What's my name?", messages: result1[:messages])
      # @example Suspend / resume flow
      #   result = agent.invoke("Perform task X")
      #   if result[:suspended]
      #     result = agent.resume(result[:checkpoint], approved: true)
      #   end
      #   puts result[:output]
      # @api public
      def invoke(input, messages: [], thread_id: nil, config: {})
        if Phronomy.configuration.event_loop
          # Protect against blocking the EventLoop thread itself.
          if Phronomy::EventLoop.current?
            raise Phronomy::Error,
              "Cannot call Agent#invoke (EventLoop mode) from within an EventLoop " \
              "entry action. Use agent.run_as_child(input, ctx: ctx) instead."
          end

          fsm = Agent::FSM.new(
            agent: self,
            input: input,
            messages: messages,
            thread_id: thread_id || SecureRandom.uuid,
            config: config
          )
          completion_queue = Phronomy::EventLoop.instance.register(fsm)
          timeout_sec = self.class.invoke_timeout
          result = if timeout_sec
            begin
              Timeout.timeout(timeout_sec) { completion_queue.pop }
            rescue Timeout::Error
              raise Phronomy::TimeoutError,
                "Agent #{self.class.name} invoke timed out after #{timeout_sec}s"
            end
          else
            completion_queue.pop
          end
          raise result if result.is_a?(Exception)
          result
        else
          _invoke_impl(input, messages: messages, thread_id: thread_id, config: config)
        end
      ensure
        # No per-thread cleanup needed: context caches are instance variables.
      end

      # Registers this agent as a child {AgentFSM} inside the given Workflow context.
      #
      # Use this method from a Workflow entry action (running on the EventLoop thread)
      # instead of {#invoke}, which would raise a deadlock error because +invoke+ blocks
      # on a +Thread::Queue+ when EventLoop mode is active.
      #
      # The agent runs asynchronously in a background IO thread.  When it finishes, the
      # parent {FSMSession} receives a +:child_completed+ event whose payload is the
      # result hash +{ output:, messages:, usage: }+.  Declare an +on: :child_completed+
      # transition in your Workflow to advance to the next state.
      #
      # An optional block may be provided to write the result back into the parent
      # WorkflowContext <b>before</b> the +:child_completed+ event is dispatched.
      # +Thread::Queue+ provides the happens-before guarantee \u2014 no Mutex is needed.
      #
      # @example Without block (result available only as event payload)
      #   entry :run_agent, ->(ctx) { MyAgent.new.run_as_child(ctx.query, ctx: ctx) }
      #   transition from: :run_agent, on: :child_completed, to: :process_result
      #
      # @example With block (writes result into context)
      #   entry :run_agent, ->(ctx) {
      #     MyAgent.new.run_as_child(ctx.query, ctx: ctx) { |r| ctx.answer = r[:output] }
      #   }
      #   transition from: :run_agent, on: :child_completed, to: :process_result
      #
      # @param input     [String, Hash]  user input passed to the agent
      # @param ctx       [Object]        a WorkflowContext that responds to +#thread_id+
      # @param messages  [Array]         prior conversation history
      # @param config    [Hash]          invocation config (forwarded to +_invoke_impl+)
      # @yield [Hash]  result hash +{ output:, messages:, usage: }+ — called from the
      #                agent IO thread before +:child_completed+ is posted
      # @return [nil]  the caller must not wait on any return value;
      #                the result arrives as a +:child_completed+ event
      # @raise [Phronomy::Error] when EventLoop mode is not enabled
      # @api public
      def run_as_child(input, ctx:, messages: [], config: {}, &result_writer)
        unless Phronomy.configuration.event_loop
          raise Phronomy::Error,
            "run_as_child requires EventLoop mode. " \
            "Enable with: Phronomy.configure { |c| c.event_loop = true }"
        end

        fsm = Agent::FSM.new(
          agent: self,
          input: input,
          messages: messages,
          thread_id: "#{ctx.thread_id}_agent_#{SecureRandom.uuid}",
          config: config,
          parent_id: ctx.thread_id,
          result_writer: result_writer
        )
        Phronomy::EventLoop.instance.enqueue_child(fsm)
        nil
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
      # @param input     [String, Hash] same as #invoke
      # @param messages  [Array<RubyLLM::Message>] same as #invoke
      # @param thread_id [String, nil] same as #invoke
      # @param config    [Hash]        same as #invoke
      # @yield [Phronomy::Agent::StreamEvent]
      # @return [Hash] { output:, messages:, usage: } — same as #invoke
      # @api public
      def stream(input, messages: [], thread_id: nil, config: {}, &block)
        return invoke(input, messages: messages, thread_id: thread_id, config: config) unless block

        _stream_impl(input, messages: messages, thread_id: thread_id, config: config, &block)
      rescue => e
        block&.call(StreamEvent.new(type: :error, payload: {error: e}))
        raise
      end

      # Returns the {Context::ContextVersionCache} built during the most recent
      # {#invoke} call on this agent instance.  The thread-local cache entry is
      # cleaned up in the +ensure+ block of {#invoke}, but a reference is kept
      # in +@last_context_version_cache+ so callers can inspect it after invoke
      # returns.
      #
      # NOTE: Not thread-safe.  When the same Agent instance is used concurrently,
      # +@last_context_version_cache+ reflects the most recent +invoke+ on *any*
      # thread.  For per-invocation isolation, use a separate Agent instance per
      # thread.
      # @api private
      def context_version_cache
        @last_context_version_cache
      end

      private

      # Streaming implementation for #stream.
      def _stream_impl(input, messages: [], thread_id: nil, config: {}, &block)
        caller_meta = {}
        caller_meta[:user_id] = config[:user_id] if config[:user_id]
        caller_meta[:session_id] = config[:session_id] if config[:session_id]

        trace("agent.invoke", input: input, **caller_meta) do |_span|
          run_input_guardrails!(input)

          chat = build_chat
          user_message = extract_message(input)

          # Assemble context (system prompt + history). Override #build_context to
          # inject custom context editing logic at the Agent subclass level.
          context = build_context(input, messages: messages, thread_id: thread_id, config: config)
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
            check_cancellation!(config, "invocation cancelled during streaming")
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
      # @param input     [String, Hash] the user's input for this turn
      # @param messages  [Array<RubyLLM::Message>] raw conversation history
      # @param thread_id [String, nil] conversation thread identifier
      # @param config    [Hash] the invocation config (see #invoke)
      # @return [Hash] { system: String|nil, messages: Array }
      # @api public
      def build_context(input, messages: [], thread_id: nil, config: {})
        history = prepare_history(messages: messages, thread_id: thread_id, config: config)
        budget = build_token_budget
        system_text = build_cached_system_text(input)
        user_message = extract_message(input)

        assembler = Context::Assembler.new(budget: budget)
        assembler.add_instruction(system_text) if system_text

        Array(config[:knowledge_sources]).each do |ks|
          check_cancellation!(config, "invocation cancelled during RAG fetch")
          ks.fetch(query: user_message, cancellation_token: config[:cancellation_token]).each do |chunk|
            assembler.add_knowledge(chunk[:content], type: chunk[:type], source: chunk[:source])
          end
        end

        assembler.add_messages(history)
        assembler.build
      end
      protected :build_context

      # Runs the on_trim / on_compaction_trigger / on_compact pipeline on the
      # supplied message array and returns the final Array of message objects
      # ready to pass to the Assembler.
      #
      # Override this method in a subclass to customize how conversation
      # history is filtered or compressed before context assembly.
      #
      # @param messages  [Array<RubyLLM::Message>] raw conversation history
      # @param thread_id [String, nil] conversation thread identifier
      # @param config    [Hash] additional invocation options
      # @return [Array] filtered and/or compacted message objects
      # @api public
      def prepare_history(messages: [], thread_id: nil, config: {})
        budget = build_token_budget
        elements = build_message_elements(Array(messages))

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
      def invoke_once(input, messages: [], thread_id: nil, config: {})
        caller_meta = {}
        caller_meta[:user_id] = config[:user_id] if config[:user_id]
        caller_meta[:session_id] = config[:session_id] if config[:session_id]

        trace("agent.invoke", input: input, **caller_meta) do |_span|
          # Run input guardrails before touching the LLM.
          run_input_guardrails!(input)

          user_message = extract_message(input)
          chat = build_chat

          # Assemble context (system prompt + history). Override #build_context to
          # inject custom context editing logic at the Agent subclass level.
          context = build_context(input, messages: messages, thread_id: thread_id, config: config)
          apply_instructions(chat, context[:system]) if context[:system]
          context[:messages].each { |msg| chat.messages << msg }

          # Run before_completion hooks (global → class → instance) before the LLM call.
          run_before_completion_hooks!(chat, config)

          # Register suspension hook for approval-required tools (no-op when a
          # synchronous on_approval_required handler is already registered).
          _register_suspension_hook!(chat)

          # Check for cancellation immediately before the LLM call.
          check_cancellation!(config, "invocation cancelled before LLM call")

          # Forward the cancellation token to ParallelToolChat explicitly
          # via the chat instance so that tool dispatch batches can observe
          # cancellation without needing Thread.current.
          chat.cancellation_token = config[:cancellation_token] if chat.respond_to?(:cancellation_token=)

          begin
            response = chat.ask(user_message)
          rescue SuspendSignal => signal
            checkpoint = Checkpoint.new(
              thread_id: thread_id,
              original_input: input,
              messages: chat.messages.dup,
              pending_tool_name: signal.tool_name,
              pending_tool_args: signal.args,
              pending_tool_call_id: signal.tool_call_id
            )
            suspended_result = {output: nil, suspended: true, checkpoint: checkpoint, messages: chat.messages}
            next [suspended_result, nil]
          ensure
            # Clear the chat's cancellation token reference after each LLM call.
            chat.cancellation_token = nil if chat.respond_to?(:cancellation_token=)
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
      # @api public
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
      # @api public
      def build_cached_system_text(input)
        instruction = build_instructions(input)

        static_chunks = self.class.static_knowledge_chunks

        fingerprint = Digest::SHA256.hexdigest(
          [instruction.to_s, *static_chunks.map { |c| c[:content] }].join("\0")
        )

        agent_id = object_id
        cache = (@context_version_cache ||= Context::ContextVersionCache.new)
        unless cache.valid?(fingerprint)
          parts = [instruction]
          static_chunks.each do |chunk|
            parts << Context::Assembler.xml_tag(chunk[:content], type: chunk[:type], trusted: true)
          end
          cache.update(fingerprint: fingerprint, system_text: parts.compact.join("\n\n"))
        end

        # Persist a reference on the instance so that context_version_cache
        # remains accessible after invoke completes.
        @last_context_version_cache = cache

        cache.system_text.empty? ? nil : cache.system_text
      end

      # Returns the chat class to instantiate for this invocation.
      # When EventLoop mode is enabled ({Phronomy.configuration.event_loop}),
      # returns {ParallelToolChat} so that concurrent tool dispatch is enabled.
      # Falls back to +nil+ otherwise, signalling {#build_chat} to use the
      # standard +RubyLLM.chat+ factory.
      def build_chat_class
        Phronomy.configuration.event_loop ? Agent::ParallelToolChat : nil
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
        parallel_class = build_chat_class
        chat = if parallel_class
          parallel_class.new(max_parallel_tools: self.class.max_parallel_tools, **opts)
        else
          RubyLLM.chat(**opts)
        end
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

      # Raises CancellationError if the cancellation_token in config is cancelled.
      # No-op when config has no cancellation_token or the token is not cancelled.
      #
      # @param config [Hash] the invocation config hash
      # @param message [String] the message for the CancellationError
      # @raise [Phronomy::CancellationError]
      # @api public
      def check_cancellation!(config, message = "invocation cancelled")
        ct = config[:cancellation_token]
        raise Phronomy::CancellationError, message if ct&.cancelled?
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
