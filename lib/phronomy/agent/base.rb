# frozen_string_literal: true

require "securerandom"
require_relative "concerns/filterable"
require_relative "concerns/before_completion"
require_relative "concerns/error_translation"

module Phronomy
  module Agent
    # Base class for all Phronomy agents.
    #
    # Subclass this to create a conversational agent powered by an LLM.
    # DSL class methods configure the model, instructions, tools, memory,
    # and execution hooks. Instance methods handle invocation.
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
      include Concerns::Filterable
      include Concerns::BeforeCompletion
      include Concerns::ErrorTranslation

      APPROVAL_CONFIGURATION_INIT_MUTEX = Mutex.new
      private_constant :APPROVAL_CONFIGURATION_INIT_MUTEX

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

        # Registers one or more static knowledge sources on the agent class.
        # Static source content is fetched and memoized at the **class** level
        # the first time +invoke+ is called. The cache persists for the lifetime
        # of the process; call {.static_knowledge_refresh!} to force a reload.
        #
        # @param sources [Array<Phronomy::Agent::Context::Knowledge::Base>]
        # @example
        #   class PolicyAgent < Phronomy::Agent::Base
        #     static_knowledge Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(POLICY_TEXT)
        #   end
        # @api public
        def static_knowledge(*sources)
          @static_knowledge_sources = sources.flatten
          # Invalidate the cached chunks so the new sources are fetched on
          # the next call to static_knowledge_chunks.
          @static_knowledge_chunks = nil
        end

        # Returns the registered static knowledge sources.
        # @return [Array<Phronomy::Agent::Context::Knowledge::Base>]
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

        # Continues a suspended AgentInvocation.
        # @param agent_invocation_id [String]
        # @param approval_request_id [String]
        # @param approved [Boolean]
        # @param config [Hash]
        # @api public
        def approve(agent_invocation_id, approval_request_id:, approved: true, config: {})
          new.approve(
            agent_invocation_id,
            approval_request_id: approval_request_id,
            approved: approved,
            config: config
          )
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

      # Registers the final Agent/Application authorization policy.
      # The block runs on the Runtime authorization pool and must return
      # :allow, :require_approval, or :reject.
      # @return [self]
      # @api public
      def tool_approval_policy(&block)
        raise ArgumentError, "tool_approval_policy requires a block" unless block

        _approval_configuration_mutex.synchronize { @tool_approval_policy = block }
        self
      end

      # Registers a non-blocking Application notification listener.
      # @return [self]
      # @api public
      def on_tool_approval_required(&block)
        raise ArgumentError, "on_tool_approval_required requires a block" unless block

        _approval_configuration_mutex.synchronize { @tool_approval_listener = block }
        self
      end

      # Invokes the agent with the given input and returns a result Hash.
      # Provider errors are translated after the configured LLM adapter returns
      # its final result. Phronomy does not replay the Agent invocation.
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
      # @raise [Phronomy::FilterBlockError] when an input or output filter rejects the value
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
        _check_scheduler_reentrancy(:invoke, :invoke_async)

        trace("agent.invoke", input: input, **_build_caller_meta(config)) do |_span|
          result = invoke_async(
            input,
            messages: messages,
            thread_id: thread_id,
            config: config
          ).wait_result
          [result, result[:usage]]
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
      #   result = task.wait_result   # => { output: "...", messages: [...], usage: ... }
      #
      # @param input    [String, Hash]
      # @param messages [Array]
      # @param thread_id [String, nil]
      # @param config   [Hash]
      # @param invocation_context [Phronomy::InvocationContext, nil]
      # @return [Phronomy::Task]
      # @api public
      def invoke_async(input, messages: [], thread_id: nil, config: {},
        invocation_context: nil, on_tool_approval_required: nil)
        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        result_task = Phronomy::Task.deferred(name: "agent-#{(self.class.name || "anonymous").downcase}-async")
        approval_snapshot = _approval_configuration_snapshot(on_tool_approval_required)
        _start_invocation(
          result_task, input,
          messages: messages, thread_id: thread_id, config: config,
          approval_snapshot: approval_snapshot
        )
        result_task
      end

      # Invokes this agent asynchronously and delivers stream events from the
      # Runtime-owned EventLoop thread.
      #
      # The callback must return quickly. Blocking I/O, synchronous Agent calls,
      # sleep, and heavy CPU work must be delegated by the Application.
      #
      # @return [Phronomy::Task] final invocation result
      # @api public
      def stream_async(input, messages: [], thread_id: nil, config: {},
        invocation_context: nil, on_tool_approval_required: nil, &block)
        raise ArgumentError, "stream_async requires a block" unless block

        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end

        result_task = Phronomy::Task.deferred(
          name: "agent-#{(self.class.name || "anonymous").downcase}-stream-async"
        )
        approval_snapshot = _approval_configuration_snapshot(on_tool_approval_required)
        _start_invocation(
          result_task,
          input,
          messages: messages,
          thread_id: thread_id,
          config: config,
          approval_snapshot: approval_snapshot,
          mode: :stream,
          on_event: block
        )
        result_task
      end

      # Synchronous wrapper around {#stream_async}.
      #
      # Stream callbacks execute on the EventLoop thread, not on the thread that
      # calls this method. This method only blocks while waiting for the final Task.
      # @yield [Phronomy::Agent::StreamEvent]
      # @return [Hash] same result shape as #invoke
      # @api public
      def stream(input, messages: [], thread_id: nil, config: {},
        invocation_context: nil, on_tool_approval_required: nil, &block)
        raise ArgumentError, "stream requires a block" unless block

        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        _check_scheduler_reentrancy(:stream, :stream_async)

        trace("agent.stream", input: input, **_build_caller_meta(config)) do |_span|
          result = stream_async(
            input,
            messages: messages,
            thread_id: thread_id,
            config: config,
            on_tool_approval_required: on_tool_approval_required,
            &block
          ).wait_result
          [result, result[:usage]]
        end
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

      def _check_scheduler_reentrancy(sync_method, async_method)
        if Phronomy::Runtime.instance.event_loop.current?
          raise Phronomy::SchedulerReentrancyError,
            "#{self.class.name}##{sync_method} cannot run on the EventLoop thread. " \
            "Use #{async_method} and return immediately."
        end

        return unless Phronomy::Task.current

        msg = "#{self.class.name}##{sync_method} called from inside a scheduler task. " \
          "This blocks the scheduler until the inner invocation completes, preventing " \
          "other tasks from making progress. Use #{async_method} + await instead."
        if Phronomy.configuration.strict_runtime_guards
          raise Phronomy::SchedulerReentrancyError, msg
        elsif Phronomy.configuration.logger
          Phronomy.configuration.logger.warn(msg)
        else
          Kernel.warn("[phronomy] WARNING: #{msg}")
        end
      end

      # Assembles the LLM context (system prompt + conversation messages)
      # for a single invocation. Subclasses may override this method to
      # inject custom context editing logic without having to override
      # the full #invoke_once pipeline.
      #
      # The keyword arguments +budget+, +instruction+, +tools+, and +knowledge+
      # carry pre-computed values. Override them in a subclass call to +super+
      # to inject custom context without recomputing the defaults.
      #
      # @param input       [String, Hash] the user's input for this turn
      # @param messages    [Array<RubyLLM::Message>] raw conversation history
      # @param thread_id   [String, nil] conversation thread identifier
      # @param config      [Hash] the invocation config (see #invoke)
      # @param budget      [LlmContextWindow::TokenBudget, nil] pre-computed token budget
      # @param instruction [String, nil] pre-computed system instruction
      # @param tools       [Array<Class>] tool classes to expose
      # @param knowledge   [Array<Hash>] knowledge chunks ({ content:, type:, source: })
      # @return [Hash] { system: String|nil, messages: Array, tool_classes: Array }
      # @api public
      def build_context(
        input,
        messages: [],
        thread_id: nil,
        config: {},
        budget: build_token_budget,
        instruction: build_instructions(input),
        tools: self.class.tools + _handoff_tools,
        knowledge: self.class.static_knowledge_chunks + instance_knowledge_chunks
      )
        assembler = LlmContextWindow::Assembler.new(budget: budget)
        assembler.add_instruction(instruction) if instruction
        assembler.add_capability(tools)
        knowledge.each { |chunk| assembler.add_knowledge(chunk[:content], type: chunk[:type] || :static, trusted: true, source: chunk[:source]) }

        msgs = Array(messages)

        if budget && budget_exceeded?(msgs)
          # Default strategy when the token budget is tight:
          # 1. Compact: keep the most recent half of the messages verbatim and
          #    replace the older half with a brief omission marker.
          # 2. Trim: if the compacted history still exceeds the budget, call
          #    trim_to_budget with the :safe strategy, which discards the oldest
          #    message one at a time until the history fits.
          # Subclasses can override build_context to apply a different strategy
          # (e.g. LLM-based summarisation) before calling super.
          keep = [msgs.size / 2, 2].max
          msgs = compact_messages(msgs, keep_tail: keep) do |dropped|
            "[#{dropped.size} earlier messages omitted]"
          end
          remaining = assembler.available_for_messages
          msgs = trim_to_budget(msgs, remaining: remaining, strategy: :safe)
        end

        assembler.add_messages(msgs)
        @last_context = assembler.build
      end
      protected :build_context

      # Keeps the last +keep+ messages from +messages+, discarding older ones.
      # Use this inside a +build_context+ override to trim conversation history.
      #
      # @param messages [Array<RubyLLM::Message>] conversation history
      # @param keep     [Integer] number of messages to retain (from the tail)
      # @return [Array<RubyLLM::Message>]
      # @api public
      def trim_messages(messages, keep:)
        Array(messages).last(keep)
      end
      protected :trim_messages

      # Removes the oldest messages one at a time until the count is within +limit+.
      #
      # @param messages [Array<RubyLLM::Message>] conversation history
      # @param limit    [Integer] maximum number of messages to retain
      # @return [Array<RubyLLM::Message>]
      # @api public
      def drop_messages_over(messages, limit:)
        msgs = Array(messages).dup
        msgs.shift while msgs.size > limit
        msgs
      end
      protected :drop_messages_over

      # Replaces all but the last +keep_tail+ messages with a single system summary.
      # The block receives the dropped messages and must return a summary String.
      #
      # @param messages  [Array<RubyLLM::Message>] conversation history
      # @param keep_tail [Integer] number of recent messages to preserve verbatim
      # @yield  [Array<RubyLLM::Message>] the messages being summarised
      # @yieldreturn [String] summary text
      # @return [Array<RubyLLM::Message>]
      # @api public
      def compact_messages(messages, keep_tail:, &summariser)
        msgs = Array(messages)
        return msgs if msgs.size <= keep_tail
        tail = msgs.last(keep_tail)
        dropped = msgs.first(msgs.size - keep_tail)
        summary_text = summariser.call(dropped)
        [RubyLLM::Message.new(role: :system, content: summary_text)] + tail
      end
      protected :compact_messages

      # Trims +messages+ to fit within +remaining+ tokens using the given
      # +strategy+. Returns the trimmed message array without touching the
      # assembler. The caller is responsible for passing the result to
      # +assembler.add_messages+ and calling +assembler.build+.
      #
      # Supported strategies:
      #   +:safe+ — discard the oldest message one at a time (default)
      #
      # @param messages  [Array<RubyLLM::Message>] conversation history
      # @param remaining [Integer, nil] token allowance for messages; when +nil+
      #   the messages are returned unchanged
      # @param strategy  [Symbol] trim strategy (default +:safe+)
      # @return [Array<RubyLLM::Message>]
      # @api public
      def trim_to_budget(messages, remaining:, strategy: :safe)
        return Array(messages) unless remaining
        msgs = Array(messages)
        loop do
          used = msgs.sum { |m| LlmContextWindow::TokenEstimator.estimate(m.content.to_s) }
          return msgs if used <= remaining
          break if msgs.empty?
          msgs = trim_messages(msgs, keep: msgs.size - 1)
        end
        msgs
      end
      protected :trim_to_budget

      # Returns +true+ when the estimated token usage of +messages+ exceeds
      # +threshold+ times the available context budget.
      # Always returns +false+ when no token budget is available.
      #
      # @param messages  [Array<RubyLLM::Message>] conversation history
      # @param threshold [Float] fraction of the available budget (default 0.8)
      # @return [Boolean]
      # @api public
      def budget_exceeded?(messages, threshold: 0.8)
        return false unless (b = build_token_budget)
        total = Array(messages).sum { |m| LlmContextWindow::TokenEstimator.estimate(m.content.to_s) }
        limit = b.available(used: 0)
        total > limit * threshold
      end
      protected :budget_exceeded?

      # Registers a per-instance knowledge source. Knowledge chunks from all
      # registered sources are included in every LLM call via +build_context+.
      #
      # @param source [#fetch] any object responding to +fetch(query:)+
      # @return [void]
      # @api public
      def add_knowledge_source(source)
        @instance_knowledge_sources ||= []
        @instance_knowledge_sources << source
      end
      protected :add_knowledge_source

      # Returns knowledge chunks fetched from all instance-level knowledge sources.
      #
      # @return [Array<Hash>]
      # @api private
      def instance_knowledge_chunks
        return [] unless @instance_knowledge_sources
        @instance_knowledge_sources.flat_map { |ks| ks.fetch(query: nil) }
      end
      protected :instance_knowledge_chunks

      # Starts one AgentInvocation and resolves +result_task+ from that session.
      # Phronomy translates the adapter's final error but never starts another
      # AgentInvocation automatically.
      # @api private
      def _start_invocation(result_task, input, messages:, thread_id:, config:,
        approval_snapshot:, mode: :invoke, on_event: nil)
        effective_config = thread_id ? config.merge(thread_id: thread_id) : config
        check_cancellation!(effective_config, "invocation cancelled")
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        session = Agent::AgentInvocationSessionBuilder.build(
          agent: self,
          input: input,
          messages: messages,
          config: effective_config,
          approval_policy: approval_snapshot[:policy],
          approval_listener: approval_snapshot[:listener],
          mode: mode,
          on_event: on_event,
          runtime: runtime
        )
        source_task = Phronomy::Task.deferred(name: "#{result_task.name}-source")
        event_loop.register(session, completion: source_task)

        source_task.on_complete do |invocation, error|
          raise error if error

          result = _extract_invoke_result(invocation)
          _emit_stream_terminal(on_event, result) if mode == :stream
          _complete_result_task(result_task, result)
        rescue => e
          translated = _translated_error(e)
          _emit_stream_error(on_event, translated) if mode == :stream
          _fail_result_task(result_task, translated)
        end
      rescue => e
        _fail_result_task(result_task, e)
      end

      def _complete_result_task(task, result)
        task.backend.unblock(result, nil)
        task.transition!(:completed, value: result)
      end

      def _fail_result_task(task, error)
        task.backend.unblock(nil, error)
        task.transition!(:failed, error: error)
      end

      def _translated_error(error)
        translate_and_reraise!(error)
      rescue => translated
        translated
      end

      # Invoked from source_task completion, which is completed by EventLoop.
      def _emit_stream_terminal(listener, result)
        return unless listener

        event = if result[:suspended]
          StreamEvent.new(
            type: :approval_required,
            payload: {request: result[:approval_request]}
          )
        else
          StreamEvent.new(type: :done, payload: result)
        end
        listener.call(event)
      end

      # Error notification is best-effort. A second callback failure must not
      # escape the EventLoop's task-completion callback.
      def _emit_stream_error(listener, error)
        return unless listener

        listener.call(StreamEvent.new(type: :error, payload: {error: error}))
      rescue => callback_error
        message = "[Phronomy] Stream error callback failed: " \
          "#{callback_error.class}: #{callback_error.message}"
        if Phronomy.configuration.logger
          Phronomy.configuration.logger.warn(message)
        else
          Kernel.warn(message)
        end
      end

      # Continues a suspended AgentInvocation. The parent session is registered
      # before child sessions so immediate child events cannot be lost.
      # @api public
      def approve(agent_invocation_id, approval_request_id:, approved: true, config: {})
        entry = Agent::AgentInvocationRegistry.consume_approval(
          agent_invocation_id, approval_request_id
        )
        unless entry
          raise ArgumentError,
            "No pending approval found for AgentInvocation #{agent_invocation_id}"
        end

        invocation = entry.invocation
        invocation.merge_config!(config)
        invocation.begin_approval_resume!(approved: approved)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        parent_task = Phronomy::Task.deferred(
          name: "agent-approval-resume:#{invocation.id}"
        )
        parent_session = Agent::AgentInvocationSessionBuilder.build_for_resume(
          agent_invocation: invocation,
          resume_event: :resume,
          resume_phase: :suspended,
          runtime: runtime
        )
        event_loop.register(parent_session, completion: parent_task)

        invocation.tool_invocations.each do |child|
          child_session = if child.awaiting_approval?
            Agent::ToolInvocationSessionBuilder.build_for_resume(
              tool_invocation: child,
              resume_event: approved ? :approve : :reject,
              resume_phase: :awaiting_approval,
              runtime: runtime
            )
          elsif !approved && child.authorized?
            Agent::ToolInvocationSessionBuilder.build_for_resume(
              tool_invocation: child,
              resume_event: :cancel,
              resume_phase: :authorized,
              runtime: runtime
            )
          end
          _register_tool_invocation_session(event_loop, runtime, child, child_session) if child_session
        end

        _extract_invoke_result(parent_task.wait_result)
      end
      public :approve

      def _extract_invoke_result(invocation)
        if invocation.phase == :suspended
          request = invocation.approval_request
          Agent::AgentInvocationRegistry.store_suspended(invocation, request)
          _dispatch_tool_approval_notification(invocation, request)
          {
            suspended: true,
            agent_invocation_id: invocation.id,
            approval_request: request,
            messages: invocation.messages
          }
        elsif invocation.input_blocked? || invocation.output_blocked?
          raise invocation.block_error
        elsif invocation.error
          raise invocation.error
        elsif invocation.rejected
          {rejected: true, messages: invocation.messages}
        else
          {output: invocation.output, messages: invocation.messages, usage: invocation.usage}
        end
      end

      def _register_tool_invocation_session(event_loop, runtime, child, session)
        completion = Phronomy::Task.deferred(name: "tool-session:#{child.id}")
        completion.on_complete do |_result, error|
          next unless error

          child.mark_framework_failed!(error)
          runtime.event_loop.post(
            Phronomy::Event.new(
              type: :tool_failed,
              target_id: child.parent_agent_invocation_id,
              payload: {tool_invocation_id: child.id}
            )
          )
        end
        event_loop.register(session, completion: completion)
      end

      def _dispatch_tool_approval_notification(invocation, request)
        listener = invocation.approval_listener
        return unless listener

        Phronomy::Runtime.instance.blocking_io.submit(on_full: :raise) do
          listener.call(request)
        end
      rescue => e
        message = "[Phronomy] Tool approval notification failed: #{e.class}: #{e.message}"
        if Phronomy.configuration.logger
          Phronomy.configuration.logger.warn(message)
        else
          Kernel.warn(message)
        end
      end

      def _approval_configuration_mutex
        return @approval_configuration_mutex if @approval_configuration_mutex

        APPROVAL_CONFIGURATION_INIT_MUTEX.synchronize do
          @approval_configuration_mutex ||= Mutex.new
        end
      end

      def _approval_configuration_snapshot(invocation_listener = nil)
        _approval_configuration_mutex.synchronize do
          {
            policy: @tool_approval_policy,
            listener: invocation_listener || @tool_approval_listener
          }.freeze
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

      # Returns the chat class to instantiate for this invocation.
      # When {Phronomy.configuration.parallel_tool_execution} is true,
      # returns {ParallelToolChat} so that concurrent tool dispatch is enabled.
      # Falls back to +nil+ otherwise, signalling {#build_chat} to use the
      # standard +RubyLLM.chat+ factory.
      def build_chat_class
        Phronomy.configuration.parallel_tool_execution ? Phronomy::MultiAgent::ParallelToolChat : nil
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
          parallel_class.new(**opts)
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

      # Builds the final Tool class to register with RubyLLM. Alias and Tool
      # result filters remain wrappers; authorization is handled only by
      # ToolInvocation before Tool#call begins.
      def prepare_tool_class(tool_class)
        return tool_class unless tool_class.is_a?(Class)

        resolved = if (alias_name = self.class.tool_aliases[tool_class])
          parent_description = tool_class.description
          Class.new(tool_class) do
            tool_name alias_name
            description parent_description if parent_description
          end
        else
          tool_class
        end

        result_filters = _tool_result_filters_for(tool_class)
        return resolved if result_filters.empty?

        effective_name = resolved.new.name
        Class.new(resolved) do
          tool_name effective_name
          define_method(:call) do |args, **kwargs|
            result = super(args, **kwargs)
            result_filters.inject(result) { |val, filter|
              filter.call(val, tool_name: name, args: args)
            }
          end
        end
      end
    end
  end
end
