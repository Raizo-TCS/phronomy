# frozen_string_literal: true

require "securerandom"
require_relative "concerns/filterable"
require_relative "concerns/before_llm_input"
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
      include Concerns::BeforeLLMInput
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

        # Tokens reserved in the legacy build_context path only.
        # Manifest-first assembly ignores this value because
        # ContextAssembler estimates actual mandatory content for each LLM Call.
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

        # Defines or reads the stable Agent definition identity.
        # Subclass with no explicit declaration inherits the parent's definition.
        def agent_definition(id: nil, version: nil)
          if id || version
            raise ArgumentError, "agent_definition requires id: and version:" unless id && version
            @agent_definition = {id: id.to_s.freeze, version: Integer(version)}.freeze
          end
          return @agent_definition if @agent_definition

          # Walk ancestors to support anonymous runtime subclasses and abstract bases.
          klass = superclass
          while klass.respond_to?(:agent_definition, true) &&
              klass < Phronomy::Agent::Base
            defn = klass.instance_variable_get(:@agent_definition)
            return defn if defn
            klass = klass.superclass
          end

          raise Phronomy::ConfigurationError,
            "#{name || self} must declare agent_definition id: ..., version: ..."
        end

        def create(agent_id: SecureRandom.uuid, context: nil, persistence: nil, metadata: {})
          new(agent_id: agent_id, context: context, persistence: persistence, metadata: metadata)
        end

        def load(agent_id, persistence:)
          new(agent_id: agent_id, persistence: persistence, load_existing: true)
        end

        def approve(execution_id, approval_request_id:, persistence:, approved: true, config: {})
          approve_async(
            execution_id,
            approval_request_id: approval_request_id,
            approved: approved,
            config: config,
            persistence: persistence
          ).wait_result
        end

        def approve_async(execution_id, approval_request_id:, persistence:, approved: true, config: {})
          execution = persistence.executions.load(execution_id)
          load(execution.agent_id, persistence: persistence).approve_async(
            execution_id,
            approval_request_id: approval_request_id,
            approved: approved,
            config: config
          )
        end
      end

      attr_reader :agent_id, :persistence

      def initialize(
        agent_id: SecureRandom.uuid,
        context: nil,
        persistence: nil,
        metadata: {},
        load_existing: false
      )
        @persistence = persistence || Phronomy::Persistence::InMemory.new
        @agent_id = agent_id.to_s.freeze
        @root = if load_existing
          loaded = @persistence.agents.load(@agent_id)
          definition = self.class.agent_definition
          unless loaded.agent_definition_id == definition.fetch(:id) &&
              loaded.definition_version == definition.fetch(:version)
            raise Phronomy::ConfigurationError,
              "Agent definition mismatch for #{@agent_id}: stored " \
              "#{loaded.agent_definition_id}@#{loaded.definition_version}, runtime " \
              "#{definition.fetch(:id)}@#{definition.fetch(:version)}"
          end
          loaded
        else
          create_agent_root!(context: context, metadata: metadata)
        end
      end

      def agent_root
        @root
      end

      def journal_projection
        Agent::JournalProjection.new(persistence: persistence, agent_root: @root)
      end

      def transcript
        journal_projection.transcript_records
      end

      def clear_transcript!
        mutate_context!(:transcript_cleared) do |root|
          root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + 1,
            transcript_generation: root.transcript_generation + 1
          )
        end
      end

      def clear_memory!
        mutate_context!(:memory_cleared) do |root|
          root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + 1,
            memory_generation: root.memory_generation + 1
          )
        end
      end

      def reset_context!
        mutate_context!(:context_reset) do |root|
          root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + 1,
            transcript_generation: root.transcript_generation + 1,
            memory_generation: root.memory_generation + 1
          )
        end
      end

      def close!
        mutate_context!(:agent_closed, context_affecting: false) do |root|
          root.with(
            agent_revision: root.agent_revision + 1,
            lifecycle_status: :closed
          )
        end
      end

      def purge!
        persistence.transaction do |tx|
          tx.executions.assert_idle!(agent_id)
          tx.journals.delete(agent_id)
          tx.executions.delete_for_agent(agent_id)
          tx.agents.delete(agent_id)
        end
        @root = nil
        true
      end

      # Internal hook used after a successful Persistence transaction.
      def __replace_root(root)
        @root = root
      end

      private

      def create_agent_root!(context:, metadata:)
        definition = self.class.agent_definition
        root = Agent::AgentRoot.create(
          agent_id: agent_id,
          agent_definition_id: definition.fetch(:id),
          definition_version: definition.fetch(:version),
          metadata: metadata
        )
        persistence.transaction do |tx|
          tx.agents.create(root)
          if context
            imported = context.respond_to?(:records) ? context :
              Agent::ContextImporter.import_messages(context)
            records = imported.records.map do |record|
              content_ref = case record.content_format
              when :text then tx.contents.put_text(record.content)
              when :json then tx.contents.put_json(record.content)
              else
                raise ArgumentError,
                  "unsupported imported content format: #{record.content_format.inspect}"
              end
              Agent::JournalRecord.new(
                agent_id: agent_id,
                kind: record.kind,
                channel: record.channel,
                role: record.role,
                content_ref: content_ref,
                context_generation: root.transcript_generation,
                context_candidate: true,
                metadata: record.metadata
              )
            end
            appended = tx.journals.append(agent_id, expected_position: 0, records: records)
            root = root.with(
              agent_revision: 1,
              context_revision: records.any? ? 1 : 0,
              journal_position: appended.length
            )
            tx.agents.save(agent_id, expected_revision: 0, root: root)
          end
        end
        root
      end

      def mutate_context!(kind, context_affecting: true)
        next_root = nil
        persistence.transaction do |tx|
          tx.executions.assert_idle!(agent_id)
          current = tx.agents.load(agent_id)
          record = Agent::JournalRecord.new(
            agent_id: agent_id,
            kind: kind,
            channel: :state,
            context_generation: current.transcript_generation,
            context_candidate: false
          )
          appended = tx.journals.append(
            agent_id,
            expected_position: current.journal_position,
            records: [record]
          )
          proposed = yield(current)
          next_root = proposed.with(
            journal_position: current.journal_position + appended.length,
            context_revision: context_affecting ?
              yield_context_revision(current, proposed) : current.context_revision
          )
          tx.agents.save(agent_id, expected_revision: current.agent_revision, root: next_root)
        end
        @root = next_root
      end

      def yield_context_revision(current, proposed)
        (proposed.context_revision == current.context_revision) ? current.context_revision + 1 : proposed.context_revision
      end

      def ensure_no_active_execution!
        return if persistence.executions.list_active(agent_id).empty?
        raise Phronomy::AgentBusyError, "agent has an active or suspended execution: #{agent_id}"
      end

      public

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

      # Registers a per-instance knowledge source. Knowledge chunks from all
      # registered sources are included in every LLM call via the Context Policy.
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

      def _build_stream_terminal_event(result)
        if result[:suspended]
          StreamEvent.new(
            type: :approval_required,
            payload: {request: result[:approval_request]}
          )
        else
          StreamEvent.new(type: :done, payload: result)
        end
      end

      # Returns the Application exception instead of allowing it to escape the
      # shared EventLoop. A nil return means delivery succeeded or no listener
      # was registered.
      def _deliver_stream_event(listener, event)
        return unless listener

        listener.call(event)
        nil
      rescue => callback_error
        callback_error
      end

      def _build_stream_callback_error(event_type:, callback_error:, result:)
        wrapped = Phronomy::StreamCallbackError.new(
          event_type: event_type,
          original_error: callback_error,
          result: result
        )

        begin
          raise wrapped, cause: callback_error
        rescue Phronomy::StreamCallbackError => error
          error.set_backtrace(callback_error.backtrace)
          error
        end
      end

      def _report_stream_callback_error(callback_error, event:, invocation_id:,
        callback_error_policy:)
        lines = [
          "[Phronomy] Stream callback failed",
          "event=#{event.type.inspect}",
          "agent_invocation_id=#{invocation_id || "unknown"}",
          "policy=#{callback_error_policy.inspect}",
          "error=#{callback_error.class}: #{callback_error.message}"
        ]
        Array(callback_error.backtrace).each { |line| lines << "  #{line}" }
        _warn_stream_callback_error(lines.join("\n"))
      rescue => reporting_error
        _kernel_warn_safely(
          "[Phronomy] Failed to report stream callback error: " \
            "#{reporting_error.class}: #{reporting_error.message}"
        )
      end

      def _warn_stream_callback_error(message)
        logger = Phronomy.configuration.logger
        unless logger
          _kernel_warn_safely(message)
          return
        end

        logger.warn(message)
      rescue => logger_error
        _kernel_warn_safely(
          "#{message}\n" \
            "[Phronomy] Logger failed while reporting a stream callback error: " \
            "#{logger_error.class}: #{logger_error.message}"
        )
      end

      def _kernel_warn_safely(message)
        Kernel.warn(message)
      rescue
        nil
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
        model_config = context[:model_config] || {}
        if context[:system]
          apply_instructions(
            chat,
            context[:system],
            cache: model_config["cache_instructions"],
            provider: model_config["provider"]
          )
        end
        (context[:tool_classes] || []).each { |tc| chat.with_tool(prepare_tool_class(tc)) }
        context[:messages].each { |msg| chat.messages << msg }
      end

      def _replace_chat_messages(chat, projection)
        chat.messages.clear
        if projection.system
          apply_instructions(
            chat,
            projection.system,
            cache: projection.model_config["cache_instructions"],
            provider: projection.model_config["provider"]
          )
        end
        projection.messages.each { |message| chat.messages << message }
        chat
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
          ruby_llm_model = RubyLLM.models.find(model_name)
          return nil unless ruby_llm_model

          registry_context = ruby_llm_model.context_window.to_i
          registry_max_output = ruby_llm_model.max_output_tokens.to_i

          # Priority: agent explicit → framework default → registry (if < context_window)
          output_reserve =
            self.class.max_output_tokens ||
            Phronomy.configuration.default_output_reserve ||
            ((registry_max_output < registry_context) ? registry_max_output : nil)

          if output_reserve.nil?
            raise Phronomy::InvalidContextBudgetConfigurationError,
              "Cannot determine output token reserve for model '#{model_name}'. " \
              "Set max_output_tokens on the agent or Phronomy.configure { |c| c.default_output_reserve = N }."
          end

          Phronomy::LlmContextWindow::TokenBudget.new(
            context_window: registry_context,
            max_output_tokens: output_reserve,
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

      def build_chat(model_config: nil)
        config = model_config || {
          "model" => self.class.model,
          "provider" => self.class.provider,
          "temperature" => self.class.temperature,
          "max_output_tokens" => self.class.max_output_tokens,
          "parallel_tool_execution" => Phronomy.configuration.parallel_tool_execution
        }
        opts = {}
        model = config["model"]
        opts[:model] = model if model
        provider = config["provider"]
        if provider
          opts[:provider] = provider.to_sym
          opts[:assume_model_exists] = true
        end
        parallel_class = config["parallel_tool_execution"] ?
          Phronomy::MultiAgent::ParallelToolChat : nil
        chat = parallel_class ? parallel_class.new(**opts) : RubyLLM.chat(**opts)
        chat.with_temperature(config["temperature"]) if config["temperature"]
        if config["max_output_tokens"] && chat.respond_to?(:with_max_output_tokens)
          chat.with_max_output_tokens(config["max_output_tokens"])
        end
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
      def apply_instructions(chat, text, cache: false, provider: nil)
        if cache && provider.to_s == "anthropic"
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
        return unless ct&.cancelled?

        # Deadline expiry is a timeout; explicit cancel! is a cancellation.
        if (ct.respond_to?(:deadline) && ct.deadline && Time.now >= ct.deadline) ||
            (ct.respond_to?(:remaining_monotonic_seconds) &&
             ct.remaining_monotonic_seconds == 0.0)
          raise Phronomy::TimeoutError, message
        end
        raise Phronomy::CancellationError, message
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
