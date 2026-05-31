# frozen_string_literal: true

require "securerandom"
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
        # Accepts a String, a {Phronomy::Agent::Context::Instruction::PromptTemplate}, or a block (Proc).
        # When used as a reader (no argument, no block), returns the stored value.
        #
        # @param text [String, Phronomy::Agent::Context::Instruction::PromptTemplate, nil]
        # @yield optionally provide instructions as a block
        # @return [String, Phronomy::Agent::Context::Instruction::PromptTemplate, Proc, nil]
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
        # When the timeout fires, a {Phronomy::Concurrency::CancellationScope} is cancelled
        # and its token is propagated to the FSM config so that in-flight LLM,
        # tool, and RAG calls observe cancellation via their +cancellation_token:+
        # keyword argument.  +Phronomy::TimeoutError+ is raised to the caller.
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
        # @param sources [Array<Phronomy::Agent::Context::Knowledge::Source::Base>]
        # @example
        #   class PolicyAgent < Phronomy::Agent::Base
        #     static_knowledge Phronomy::Agent::Context::Knowledge::Source::StaticKnowledge.new(POLICY_TEXT)
        #   end
        # @api public
        def static_knowledge(*sources)
          @static_knowledge_sources = sources.flatten
          # Invalidate the cached chunks so the new sources are fetched on
          # the next call to static_knowledge_chunks.
          @static_knowledge_chunks = nil
        end

        # Returns the registered static knowledge sources.
        # @return [Array<Phronomy::Agent::Context::Knowledge::Source::Base>]
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
        # The block receives a {Phronomy::Agent::Context::Conversation::TrimContext} and may call
        # +ctx.remove(seqs)+ to drop messages by seq number. Changes affect
        # only the current invocation; the underlying memory store is unchanged.
        #
        # @yield [ctx] Phronomy::Agent::Context::Conversation::TrimContext
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
        # The block receives a read-only {Phronomy::Agent::Context::Conversation::TriggerContext}.
        #
        # @yield [ctx] Phronomy::Agent::Context::Conversation::TriggerContext
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
        # {Phronomy::Agent::Context::Conversation::CompactionContext} and should call +ctx.compact+
        # to specify which messages to summarise.
        #
        # @yield [ctx] Phronomy::Agent::Context::Conversation::CompactionContext
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
      # @param tool_class [Class<Phronomy::Agent::Context::Capability::Base>]
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
      # @param invocation_context [Phronomy::InvocationContext, nil] optional first-class context
      #   object.  When present, +thread_id+, +cancellation_token+, and +deadline+ are
      #   derived from it (existing +config:+ keys take precedence as backward-compat
      #   aliases).  The object is also stored in +config[:invocation_context]+ so that
      #   +task_id+ / +parent_task_id+ appear in trace spans automatically.
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
      # @example With InvocationContext (deadline-based timeout)
      #   ctx = Phronomy::InvocationContext.new(
      #     thread_id: "conv-123",
      #     deadline: Phronomy::Concurrency::Deadline.in(30),
      #     task_id: SecureRandom.uuid
      #   )
      #   result = MyAgent.new.invoke("Hello", invocation_context: ctx)
      # @api public
      def invoke(input, messages: [], thread_id: nil, config: {}, invocation_context: nil)
        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        if Phronomy.configuration.event_loop
          _invoke_via_event_loop(input, messages: messages, thread_id: thread_id, config: config)
        else
          _check_scheduler_reentrancy
          invoke_async(input, messages: messages, thread_id: thread_id, config: config).await
        end
      end

      # Invokes this agent asynchronously and returns a {Phronomy::Task}.
      #
      # This is the primary async entry point.  {#invoke} is a synchronous wrapper
      # that calls this method and blocks the caller until the task completes.
      # Calling {#invoke} from inside an active scheduler task raises
      # {Phronomy::SchedulerReentrancyError}; use +invoke_async+ directly in that
      # context.
      #
      # The task is registered with the Runtime task registry so {Runtime#shutdown}
      # drains in-flight invocations before process exit.
      #
      # @example
      #   task = agent.invoke_async("Hello!")
      #   result = task.await   # => { output: "...", messages: [...], usage: ... }
      #
      # @param input    [String, Hash]
      # @param messages [Array]
      # @param thread_id [String, nil]
      # @param config   [Hash]
      # @param invocation_context [Phronomy::InvocationContext, nil]
      # @return [Phronomy::Task]
      # @api public
      def invoke_async(input, messages: [], thread_id: nil, config: {}, invocation_context: nil)
        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        bp = Phronomy.configuration.backpressure
        on_full = (bp == :raise) ? :reject : (bp || :wait)
        bp_timeout = Phronomy.configuration.backpressure_timeout
        gate = Phronomy::Runtime.instance.gate(:agent)
        Phronomy::Runtime.instance.spawn(name: "agent-#{(self.class.name || "anonymous").downcase}-async") do
          gate.acquire(on_full: on_full, timeout: bp_timeout) do
            _invoke_impl(input, messages: messages, thread_id: thread_id, config: config)
          end
        end
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
      # The result is delivered exclusively as the +:child_completed+ event payload.
      # The parent Workflow task is the sole owner of the parent +WorkflowContext+ and
      # applies the result after receiving the event — no background thread writes to
      # the parent context directly.
      #
      # @example
      #   entry :run_agent, ->(ctx) { MyAgent.new.run_as_child(ctx.query, ctx: ctx) }
      #   transition from: :run_agent, on: :child_completed, to: :process_result
      #
      # @param input     [String, Hash]  user input passed to the agent
      # @param ctx       [Object]        a WorkflowContext that responds to +#thread_id+
      # @param messages  [Array]         prior conversation history
      # @param config    [Hash]          invocation config (forwarded to +_invoke_impl+)
      # @return [nil]  the caller must not wait on any return value;
      #                the result arrives as a +:child_completed+ event
      # @raise [Phronomy::Error] when EventLoop mode is not enabled
      # @api public
      def run_as_child(input, ctx:, messages: [], config: {})
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
          parent_id: ctx.thread_id
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

      # @deprecated The context version cache has been removed. Returns nil.
      #   Retained for backward compatibility with callers using safe navigation (+&.reset+).
      # @api private
      def context_version_cache
        nil
      end

      private

      # Merges an {InvocationContext} into the +thread_id+ / +config+ pair.
      # Returns +[effective_thread_id, effective_config]+.
      #
      # Precedence rules (existing explicit values always win):
      # - +thread_id+ argument > +ic.thread_id+
      # - +config[:cancellation_token]+ > +ic.cancellation_token+ > token derived from +ic.deadline+
      # - +ic+ is stored in +config[:invocation_context]+ (overwriting any previous value)
      def _apply_invocation_context(thread_id, config, ic)
        effective_thread_id = thread_id || ic.thread_id
        effective_config = config.merge(invocation_context: ic)
        if effective_config[:cancellation_token].nil?
          if (tok = ic.effective_timeout_token)
            effective_config = effective_config.merge(cancellation_token: tok)
          end
        end
        [effective_thread_id, effective_config]
      end

      def _invoke_via_event_loop(input, messages:, thread_id:, config:)
        if Phronomy::EventLoop.current?
          raise Phronomy::Error,
            "Cannot call Agent#invoke (EventLoop mode) from within an EventLoop " \
            "entry action. Use agent.run_as_child(input, ctx: ctx) instead."
        end

        timeout_sec = self.class.invoke_timeout
        effective_config, scope = if timeout_sec
          s = Phronomy::Concurrency::CancellationScope.new(parent_token: config[:cancellation_token])
          s.deadline_in(timeout_sec)
          [config.merge(cancellation_token: s.token), s]
        else
          [config, nil]
        end

        fsm = Agent::FSM.new(
          agent: self,
          input: input,
          messages: messages,
          thread_id: thread_id || SecureRandom.uuid,
          config: effective_config
        )
        completion_queue = Phronomy::EventLoop.instance.register(fsm)
        result = if scope
          scope.pop_queue(completion_queue) do
            raise Phronomy::TimeoutError,
              "Agent #{self.class.name} invoke timed out after #{timeout_sec}s"
          end
        else
          completion_queue.pop
        end
        raise result if result.is_a?(Exception)
        result
      end

      def _check_scheduler_reentrancy
        return unless Phronomy::Task.current

        msg = "#{self.class.name}#invoke called from inside a scheduler task. " \
          "This blocks the scheduler until the inner invocation completes, preventing " \
          "other tasks from making progress. Use invoke_async + await instead."
        if Phronomy.configuration.strict_runtime_guards
          raise Phronomy::SchedulerReentrancyError, msg
        elsif Phronomy.configuration.logger
          Phronomy.configuration.logger.warn(msg)
        else
          Kernel.warn("[phronomy] WARNING: #{msg}")
        end
      end

      # Streaming implementation for #stream.
      def _stream_impl(input, messages: [], thread_id: nil, config: {}, &block)
        trace("agent.invoke", input: input, **_build_caller_meta(config)) do |_span|
          run_input_guardrails!(input)

          chat = build_chat
          user_message = extract_message(input)
          context = build_context(input, messages: messages, thread_id: thread_id, config: config)
          _apply_context_to_chat(chat, context)

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

          run_before_completion_hooks!(chat, config)

          output, usage = _drain_stream(chat, user_message, config, &block)
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
      # @param config      [Hash] the invocation config (see #invoke)
      # @return [Hash] { system: String|nil, messages: Array, tool_classes: Array }
      # @api public
      def build_context(input, messages: [], thread_id: nil, config: {})
        history = prepare_history(messages: messages, thread_id: thread_id, config: config)
        budget = build_token_budget
        instruction = build_instructions(input)

        assembler = LlmContextWindow::Assembler.new(budget: budget)
        assembler.add_instruction(instruction) if instruction
        assembler.add_capability(self.class.tools + _handoff_tools)
        self.class.static_knowledge_chunks.each do |chunk|
          assembler.add_knowledge(chunk[:content], type: chunk[:type] || :static, trusted: true, source: chunk[:source])
        end
        assembler.add_messages(history)
        @last_context = assembler.build
      end
      protected :build_context

      # Fetches knowledge chunks from all registered sources concurrently.
      #
      # Each source is spawned as a separate task within a {Phronomy::TaskGroup};
      # the RAG concurrency gate enforces the +max_concurrent_rag_fetches+ cap.
      # Results are returned in registration order (spawn order) as a flat array.
      #
      # This method is available to subclasses as a building block when
      # overriding {#build_context}. Pass a custom +query+ to implement
      # multi-hop RAG or other retrieval strategies.
      #
      # @param query  [String] RAG query string (typically the current user message)
      # @param config [Hash]   invocation config; relevant keys:
      #   +:knowledge_sources+, +:rag_failure_policy+, +:cancellation_token+, +:rag_timeout+
      # @return [Array<Hash>] flat list of chunk hashes with +:content+, +:type+, +:source+
      # @api private
      def fetch_knowledge_chunks(query, config)
        sources = Array(config[:knowledge_sources])
        return [] if sources.empty?

        check_cancellation!(config, "invocation cancelled before RAG fetch")

        # :skip (default) — ignore per-source failures so the agent can still
        # answer with partial context. :fail surfaces the first error immediately.
        failure_policy =
          case config[:rag_failure_policy]
          when :fail then :fail_fast
          else :skip_failed
          end

        group = Phronomy::Runtime.instance.task_group(failure_policy: failure_policy)
        bp = Phronomy.configuration.backpressure
        rag_on_full = (bp == :raise) ? :reject : (bp || :wait)
        rag_bp_timeout = Phronomy.configuration.backpressure_timeout

        # Spawn all fetches concurrently. Results are returned in spawn order
        # (i.e. registration order of knowledge sources) by TaskGroup#await_all.
        sources.each do |ks|
          group.spawn do
            Phronomy::Runtime.instance.gate(:rag).acquire(on_full: rag_on_full, timeout: rag_bp_timeout) do
              result, elapsed_ms = Phronomy::Runtime.measure_ms do
                ks.fetch_async(
                  query: query,
                  cancellation_token: config[:cancellation_token],
                  timeout: config[:rag_timeout]
                ).await
              end
              Phronomy.configuration.logger&.debug { "RAG fetch from #{ks.class.name} completed in #{elapsed_ms}ms" }
              result
            end
          end
        end

        # await_all returns results in spawn order; nil entries indicate
        # skipped failures when using :skip_failed.
        group.await_all.flat_map { |chunks| Array(chunks) }
      end
      protected :fetch_knowledge_chunks

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
          trim_ctx = Context::Conversation::TrimContext.new(message_elements: elements, budget: budget)
          trim_cb.call(trim_ctx)
          elements = trim_ctx.message_elements
        end

        if (trigger_cb = self.class._on_compaction_trigger_callback)
          trigger_ctx = Context::Conversation::TriggerContext.new(message_elements: elements, budget: budget)
          if trigger_cb.call(trigger_ctx)
            if (compact_cb = self.class._on_compact_callback)
              compact_ctx = Context::Conversation::CompactionContext.new(
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
        trace("agent.invoke", input: input, **_build_caller_meta(config)) do |_span|
          Agent::InvocationPipeline.new(self).run(
            input,
            messages: messages,
            thread_id: thread_id,
            config: config
          )
        end
      end

      def _build_caller_meta(config)
        meta = {}
        meta[:user_id] = config[:user_id] if config[:user_id]
        meta[:session_id] = config[:session_id] if config[:session_id]
        if (ic = config[:invocation_context])
          meta[:task_id] = ic.task_id if ic.task_id
          meta[:parent_task_id] = ic.parent_task_id if ic.parent_task_id
        end
        meta
      end

      def _apply_context_to_chat(chat, context)
        apply_instructions(chat, context[:system]) if context[:system]
        (context[:tool_classes] || []).each { |tc| chat.with_tool(prepare_tool_class(tc)) }
        context[:messages].each { |msg| chat.messages << msg }
      end

      def _drain_stream(chat, user_message, config, &block)
        adapter = Phronomy.configuration.llm_adapter
        chunk_queue = Phronomy::Concurrency::AsyncQueue.new(max_size: Phronomy.configuration.stream_queue_max_size)
        pending = adapter.stream_async(chat, user_message, config: config, enqueue_to: chunk_queue)

        loop do
          chunk = chunk_queue.pop
          break if chunk.nil?
          block.call(StreamEvent.new(type: :token, payload: {content: chunk.content}))
          check_cancellation!(config, "invocation cancelled during streaming")
        end

        response = pending.await
        [response.content, Phronomy::TokenUsage.from_tokens(response.tokens)]
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
          Phronomy::LlmContextWindow::TokenBudget.new(
            context_window: cw,
            max_output_tokens: self.class.max_output_tokens || 0,
            overhead: self.class.context_overhead
          )
        else
          Phronomy::LlmContextWindow::TokenBudget.new(
            model: model_name,
            max_output_tokens: self.class.max_output_tokens,
            overhead: self.class.context_overhead
          )
        end
      rescue Phronomy::LlmContextWindow::UnknownModelError, RubyLLM::ModelNotFoundError
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
          tokens = LlmContextWindow::TokenEstimator.estimate(msg.content.to_s)
          {seq: idx, message: msg, tokens: tokens, role: msg.role}
        end
      end

      # Returns the chat class to instantiate for this invocation.
      # When EventLoop mode is enabled ({Phronomy.configuration.event_loop}),
      # returns {ParallelToolChat} so that concurrent tool dispatch is enabled.
      # Falls back to +nil+ otherwise, signalling {#build_chat} to use the
      # standard +RubyLLM.chat+ factory.
      def build_chat_class
        Phronomy.configuration.event_loop ? Phronomy::MultiAgent::ParallelToolChat : nil
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
        chat
      end

      def build_instructions(input)
        instr = self.class.instructions
        case instr
        when Phronomy::Agent::Context::Instruction::PromptTemplate
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
      # When an already-instantiated tool object is passed (e.g. a
      # {Phronomy::Agent::Context::Capability::McpTool} returned by +McpTool.from_server+), it is
      # returned as-is.  RubyLLM's +with_tool+ accepts both classes and
      # instances, so no wrapping is needed.
      #
      # For tool classes, three transformations are applied in order:
      #   1. Alias override — when the Hash form of .tools maps this class to an
      #      explicit name, an anonymous subclass with that tool_name is returned.
      #   2. Scope policy   — when a scope is declared on the tool, the configured
      #      {Phronomy::Agent::Context::Capability::ScopePolicy} (or the default) is evaluated.
      #      +:reject+ wraps the tool to return a denial message without executing.
      #      +:approve+ behaves like requiring approval (same as step 3 when the
      #      tool does not already have +requires_approval+).
      #   3. Approval gate  — when the tool class has +requires_approval+ set AND
      #      an approval handler has been registered via #on_approval_required,
      #      the tool's #call method is wrapped: the handler is invoked with
      #      (tool_name, args) and, if it returns falsy, the tool returns a denial
      #      message instead of executing.
      def prepare_tool_class(tool_class)
        # When an instantiated tool object is passed (e.g. McpTool.from_server
        # returns an instance, not a class), skip class-level processing and
        # return it directly. RubyLLM#with_tool handles both forms.
        return tool_class unless tool_class.is_a?(Class)

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

        # Step 2: evaluate scope policy.
        scope = resolved.scope
        if scope
          policy = @scope_policy || Phronomy::Agent::Context::Capability::ScopePolicy::DEFAULT
          decision = policy.call(resolved, scope, self)
          case decision
          when :reject
            effective_name = resolved.new.name
            rejected_class = Class.new(resolved) do
              tool_name effective_name
              define_method(:call) do |_args|
                "Tool execution denied: scope :#{scope} is not permitted."
              end
            end
            return rejected_class
          when :approve
            # Treat as requires_approval unless the tool already has that flag.
            unless resolved.requires_approval
              effective_name = resolved.new.name
              resolved = Class.new(resolved) do
                tool_name effective_name
                requires_approval true
              end
            end
          end
        end

        # Step 3: wrap with approval gate when handler is registered.
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
