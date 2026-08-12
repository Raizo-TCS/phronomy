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
    # DSL class methods configure the model, instructions, tools,
    # and execution hooks. Instance methods handle invocation.
    #
    # @example Minimal agent
    #   class GreetingAgent < Phronomy::Agent::Base
    #     agent_definition id: "greeting-agent", version: 1
    #     model "gpt-4o-mini"
    #     instructions "You are a friendly greeter."
    #   end
    #   result = GreetingAgent.new.invoke("Hello!")
    #   puts result[:output]
    #
    # @example Agent with tools
    #   class ResearchAgent < Phronomy::Agent::Base
    #     agent_definition id: "research-agent", version: 1
    #     model "gpt-4o"
    #     instructions "You are a research assistant."
    #     tools(WebSearchTool => nil, CalculatorTool => nil)
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
        # The setter accepts one Hash mapping each Tool class to an explicit alias
        # name (String) or nil (use the Tool's own name). Calling without an
        # argument returns the registered Tool classes.
        #
        # @example
        #   tools(
        #     Weather::SearchTool => "weather_search",
        #     Places::SearchTool  => "places_search",
        #     CurrentTimeTool     => nil
        #   )
        # @api public
        def tools(definitions = nil)
          if definitions.nil?
            return @tools if instance_variable_defined?(:@tools)
            return superclass.respond_to?(:tools) ? superclass.tools : []
          end

          unless definitions.is_a?(Hash)
            raise ArgumentError,
              "tools expects a Hash of ToolClass => alias_or_nil"
          end

          @tools = definitions.keys
          @tool_aliases = definitions.transform_values { |value| value&.to_s }
            .reject { |_, value| value.nil? }
        end

        # Returns the alias map registered via .tools.
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

        # When enabled, attaches Anthropic prompt-cache markers to the system
        # message so that the fixed instructions are served from cache on
        # subsequent turns, reducing input-token costs.
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
        # @api public
        def max_output_tokens(val = nil)
          if val.nil?
            @max_output_tokens
          else
            @max_output_tokens = val.to_i
          end
        end

        # Overrides the context window size used for token budget calculations.
        # @api public
        def context_window(val = nil)
          if val.nil?
            @context_window
          else
            @context_window = val.to_i
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

        def create(agent_id: SecureRandom.uuid, context: nil, knowledge: [], persistence: nil, metadata: {})
          new(
            agent_id: agent_id,
            context: context,
            knowledge: knowledge,
            persistence: persistence,
            metadata: metadata
          )
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
        knowledge: [],
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
          create_agent_root!(context: context, knowledge: knowledge, metadata: metadata)
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

      # Logically clears all persistent Knowledge registered before this point.
      # Raw Journal records remain append-only and are not deleted.
      def clear_knowledge!
        mutate_context!(:knowledge_cleared) do |root|
          root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + 1
          )
        end
      end

      # Appends persistent Knowledge to the Agent Journal.
      # Knowledge is an optional Context candidate; it is not part of #transcript.
      def add_knowledge(content, metadata: {})
        next_root = nil
        persistence.transaction do |tx|
          tx.executions.assert_idle!(agent_id)
          current = tx.agents.load(agent_id)
          record = build_knowledge_record(
            tx: tx,
            root: current,
            content: content,
            metadata: metadata
          )
          appended = tx.journals.append(
            agent_id,
            expected_position: current.journal_position,
            records: [record]
          )
          next_root = current.with(
            agent_revision: current.agent_revision + 1,
            context_revision: current.context_revision + 1,
            journal_position: current.journal_position + appended.length
          )
          tx.agents.save(
            agent_id,
            expected_revision: current.agent_revision,
            root: next_root
          )
        end
        @root = next_root
        self
      end

      def reset_context!
        mutate_context!(:context_reset) do |root|
          root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + 1,
            transcript_generation: root.transcript_generation + 1
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

      def create_agent_root!(context:, knowledge:, metadata:)
        definition = self.class.agent_definition
        root = Agent::AgentRoot.create(
          agent_id: agent_id,
          agent_definition_id: definition.fetch(:id),
          definition_version: definition.fetch(:version),
          metadata: metadata
        )
        persistence.transaction do |tx|
          tx.agents.create(root)
          records = initial_context_records(tx: tx, root: root, context: context)
          records.concat(initial_knowledge_records(tx: tx, root: root, knowledge: knowledge))
          unless records.empty?
            appended = tx.journals.append(agent_id, expected_position: 0, records: records)
            root = root.with(
              agent_revision: 1,
              context_revision: 1,
              journal_position: appended.length
            )
            tx.agents.save(agent_id, expected_revision: 0, root: root)
          end
        end
        root
      end

      def initial_context_records(tx:, root:, context:)
        return [] unless context

        imported = context.respond_to?(:records) ? context :
          Agent::ContextImporter.import_messages(context)
        imported.records.map do |record|
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
      end

      def initial_knowledge_records(tx:, root:, knowledge:)
        Array(knowledge).map do |content|
          build_knowledge_record(
            tx: tx,
            root: root,
            content: content,
            metadata: {}
          )
        end
      end

      def build_knowledge_record(tx:, root:, content:, metadata:)
        Agent::JournalRecord.new(
          agent_id: agent_id,
          kind: :knowledge,
          channel: :context,
          role: :user,
          content_ref: tx.contents.put_text(String(content)),
          context_generation: root.transcript_generation,
          context_candidate: true,
          metadata: metadata || {}
        )
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

      public

      def _add_handoff_tool(tool_class)
        @_handoff_tools ||= []
        @_handoff_tools << tool_class
        self
      end

      def _handoff_tools
        @_handoff_tools || []
      end

      def tool_approval_policy(&block)
        raise ArgumentError, "tool_approval_policy requires a block" unless block

        _approval_configuration_mutex.synchronize { @tool_approval_policy = block }
        self
      end

      def on_tool_approval_required(&block)
        raise ArgumentError, "on_tool_approval_required requires a block" unless block

        _approval_configuration_mutex.synchronize { @tool_approval_listener = block }
        self
      end

      private

      def _apply_invocation_context(thread_id, config, ic)
        effective_thread_id = thread_id || ic.thread_id
        effective_config = config.merge(invocation_context: ic)
        if effective_config[:cancellation_token].nil?
          if (tok = ic.effective_timeout_token)
            effective_config = effective_config.merge(
              cancellation_token: tok,
              phronomy_timeout_deadline: ic.deadline
            )
          end
        end
        [effective_thread_id, effective_config]
      end

      def _check_event_loop_reentrancy(sync_method, async_method)
        if Phronomy::Runtime.instance.event_loop.current?
          raise Phronomy::EventLoopReentrancyError,
            "#{self.class.name}##{sync_method} cannot run on the EventLoop thread. " \
            "Use #{async_method} and return immediately."
        end
      end

      def _complete_result_task(task, result)
        task.complete(result)
      end

      def _fail_result_task(task, error)
        task.fail(error)
      end

      def _translated_error(error)
        translate_and_reraise!(error)
      rescue => translated
        translated
      end

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

      def _apply_runtime_projection_to_chat(chat, projection, invocation: nil)
        if projection.system
          apply_instructions(
            chat,
            projection.system,
            cache: projection.model_config["cache_instructions"],
            provider: projection.model_config["provider"]
          )
        end
        projection.tool_classes.each do |tool_class|
          chat.with_tool(prepare_tool_class(tool_class, invocation: invocation))
        end
        projection.messages.each { |message| chat.messages << message }
        chat
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

      def apply_instructions(chat, text, cache: false, provider: nil)
        if cache && provider.to_s == "anthropic"
          content = RubyLLM::Providers::Anthropic::Content.new(text, cache: true)
          chat.with_instructions(content)
        else
          chat.with_instructions(text)
        end
      end

      def extract_message(input)
        case input
        when String then input
        when Hash then input[:message] || input[:query] || input[:user] || input.to_s
        else input.to_s
        end
      end

      def check_cancellation!(config, message = "invocation cancelled")
        timeout_deadline = config[:phronomy_timeout_deadline]
        raise Phronomy::TimeoutError, message if timeout_deadline&.expired?

        ct = config[:cancellation_token]
        return unless ct&.cancelled?

        if ct.respond_to?(:remaining_monotonic_seconds) &&
            ct.remaining_monotonic_seconds == 0.0
          raise Phronomy::TimeoutError, message
        end
        raise Phronomy::CancellationError, message
      end

      def prepare_tool_class(tool_class, invocation: nil)
        return tool_class unless tool_class.is_a?(Class)

        resolved = if (alias_name = self.class.tool_aliases[tool_class])
          Class.new(tool_class) do
            tool_name alias_name
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
