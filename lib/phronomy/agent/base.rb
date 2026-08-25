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
        def model(name = nil)
          if name
            @model = name
          else
            @model || Phronomy.configuration.default_model
          end
        end

        def instructions(text = nil, &block)
          if text || block_given?
            @instructions = text || block
          else
            return @instructions if instance_variable_defined?(:@instructions)
            superclass.respond_to?(:instructions) ? superclass.instructions : nil
          end
        end

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

        def tool_aliases
          own = @tool_aliases || {}
          if superclass.respond_to?(:tool_aliases)
            superclass.tool_aliases.merge(own)
          else
            own
          end
        end

        def provider(name = nil)
          if name
            @provider = name
          else
            return @provider if instance_variable_defined?(:@provider)
            superclass.respond_to?(:provider) ? superclass.provider : nil
          end
        end

        def temperature(val = nil)
          if val
            @temperature = val
          else
            @temperature
          end
        end

        def max_iterations(val = nil)
          if val
            @max_iterations = val
          else
            @max_iterations || 10
          end
        end

        def cache_instructions(enabled = nil)
          if enabled.nil?
            @cache_instructions
          else
            @cache_instructions = enabled
          end
        end

        def max_output_tokens(val = nil)
          if val.nil?
            @max_output_tokens
          else
            @max_output_tokens = val.to_i
          end
        end

        def context_window(val = nil)
          if val.nil?
            @context_window
          else
            @context_window = val.to_i
          end
        end

        def agent_definition(id: nil, version: nil)
          if !id.nil? || !version.nil?
            raise ArgumentError, "agent_definition requires version:" if version.nil?

            definition_id = id || name
            unless definition_id
              raise Phronomy::ConfigurationError,
                "anonymous Agent class must declare agent_definition id: ..., version: ..."
            end

            @agent_definition = {
              id: definition_id.to_s.freeze,
              version: Integer(version)
            }.freeze
          end
          return @agent_definition if @agent_definition

          raise Phronomy::ConfigurationError,
            "#{name || self} must declare agent_definition version: ..."
        end

        def create(
          agent_id: SecureRandom.uuid,
          context: nil,
          knowledge: [],
          persistence: nil,
          metadata: {},
          on_event: nil,
          &event_block
        )
          new(
            agent_id: agent_id,
            context: context,
            knowledge: knowledge,
            persistence: persistence,
            metadata: metadata,
            on_event: on_event,
            &event_block
          )
        end

        # Resolves one existing logical Agent. A live process-local owner wins
        # without a Persistence reload; otherwise the durable Agent is hydrated.
        def load(agent_id, persistence:, on_event: nil, &event_block)
          raise ArgumentError, "persistence is required" unless persistence
          if on_event && event_block
            raise ArgumentError, "Provide either on_event: or a block, not both"
          end

          key = agent_id.to_s
          raise ArgumentError, "agent_id must not be empty" if key.empty?

          listener_supplied = !on_event.nil? || !event_block.nil?
          runtime = Phronomy::Runtime.instance
          materialized = false

          agent = runtime.__load_agent(key, expected_class: self) do |owner_runtime|
            materialized = true
            instance = __construct_owned_agent(
              owner_runtime,
              key,
              agent_id: key,
              persistence: persistence,
              load_existing: true,
              on_event: on_event,
              &event_block
            )
            Phronomy::Agent::RecoveryCoordinator.new(instance).recover_on_load!
            instance
          end

          unless agent.persistence.equal?(persistence)
            raise Phronomy::ConfigurationError,
              "Agent #{key.inspect} is already live with a different Persistence instance"
          end

          if !materialized && listener_supplied
            raise Phronomy::ConfigurationError,
              "Agent #{key.inspect} is already live; load cannot add, replace, or re-bind on_event"
          end

          agent
        end

        # Returns only the process-local live Agent owner. Does not access
        # Persistence and returns nil when this Runtime has no live owner.
        def get(agent_id)
          Phronomy::Runtime.instance.__get_agent(agent_id, expected_class: self)
        end

        # Resolves the live Agent instance that currently owns execution_id in
        # this process. The Runtime returns only a read-only ownership view;
        # mutable Agent execution state remains EventLoop-owned.
        def live_for_execution(execution_id)
          owner = Phronomy::Runtime.instance.__agent_execution_owner(execution_id)
          unless owner
            raise Phronomy::ExecutionRehydrationRequiredError,
              "no live execution owner for #{execution_id}; durable rehydration is required"
          end

          agent = owner.agent
          unless agent.is_a?(self)
            raise ArgumentError,
              "live execution #{execution_id} belongs to #{agent.class}, not #{self}"
          end

          agent
        end

        private

        def __construct_owned_agent(owner_runtime, reserved_agent_id, *args, **kwargs, &block)
          instance = allocate
          instance.send(:__prepare_runtime_owner!, owner_runtime, reserved_agent_id)
          instance.send(:initialize, *args, **kwargs, &block)
          instance
        end
      end

      attr_reader :agent_id, :persistence

      def initialize(
        agent_id: nil,
        context: nil,
        knowledge: [],
        persistence: nil,
        metadata: {},
        load_existing: false,
        on_event: nil,
        &event_block
      )
        if on_event && event_block
          raise ArgumentError, "Provide either on_event: or a block, not both"
        end
        @_phronomy_event_listener = on_event || event_block

        reserved_agent_id = @_phronomy_reserved_agent_id
        effective_agent_id = if agent_id.nil?
          reserved_agent_id || SecureRandom.uuid.to_s
        else
          agent_id.to_s
        end
        raise ArgumentError, "agent_id must not be empty" if effective_agent_id.empty?

        if @_phronomy_runtime_owner_state == :constructing
          unless reserved_agent_id == effective_agent_id
            raise Phronomy::Error,
              "Agent initializer changed reserved identity from " \
              "#{reserved_agent_id.inspect} to #{effective_agent_id.inspect}"
          end
          initialize_owned_state(
            agent_id: effective_agent_id,
            context: context,
            knowledge: knowledge,
            persistence: persistence,
            metadata: metadata,
            load_existing: load_existing
          )
          return
        end

        if load_existing
          raise ArgumentError,
            "load_existing: is an internal hydration option; use .load(agent_id, persistence:)"
        end

        runtime = Phronomy::Runtime.instance
        begin
          runtime.__create_agent(effective_agent_id, expected_class: self.class) do |owner_runtime|
            __prepare_runtime_owner!(owner_runtime, effective_agent_id)
            initialize_owned_state(
              agent_id: effective_agent_id,
              context: context,
              knowledge: knowledge,
              persistence: persistence,
              metadata: metadata,
              load_existing: false
            )
            self
          end
        rescue Phronomy::Persistence::ConflictError => error
          raise Phronomy::AgentAlreadyExistsError,
            "Agent #{effective_agent_id.inspect} already exists durably: #{error.message}"
        end
      end

      def agent_root
        __assert_agent_accessible!
        @root
      end

      def journal_projection
        __assert_agent_accessible!
        Agent::JournalProjection.new(
          agent_root: @root,
          records: _journal_records_snapshot
        )
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

      def clear_knowledge!
        mutate_context!(:knowledge_cleared) do |root|
          root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + 1
          )
        end
      end

      def add_knowledge(content, metadata: {})
        __assert_live_agent!
        current = agent_root
        next_root = nil
        appended = nil
        persistence.transaction do |tx|
          tx.executions.assert_idle!(agent_id)
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
        _append_journal_records(appended)
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
        return true if @_phronomy_runtime_owner_state == :purged

        __assert_live_agent!
        runtime = @_phronomy_runtime_owner
        token = runtime.__begin_agent_purge(self)
        if runtime.__agent_execution_admitted?(agent_id)
          runtime.__abort_agent_purge(self, token)
          raise Phronomy::AgentBusyError,
            "Agent #{agent_id.inspect} has a nonterminal top-level execution"
        end

        begin
          persistence.transaction do |tx|
            tx.executions.assert_idle!(agent_id)
            tx.journals.delete(agent_id)
            tx.executions.delete_for_agent(agent_id)
            tx.agents.delete(agent_id)
          end
        rescue Phronomy::AgentBusyError,
          Phronomy::Persistence::ConflictError,
          Phronomy::Persistence::NotFoundError,
          Phronomy::Persistence::SerializationError,
          ArgumentError
          runtime.__abort_agent_purge(self, token)
          raise
        rescue
          # Without F1 reconciliation support we cannot infer that a failed
          # durable delete did not commit. Keep the identity fail-closed.
          runtime.__leave_agent_purge_uncertain(self, token)
          raise
        end

        runtime.__complete_agent_purge(self, token)
        true
      end

      # Runtime ownership lifecycle hooks. These are internal coordination
      # methods; application code must use new/create/load/get/purge!.
      private

      # @api private
      def __prepare_runtime_owner!(runtime, reserved_agent_id)
        @_phronomy_runtime_owner = runtime
        @_phronomy_runtime_owner_state = :constructing
        @_phronomy_reserved_agent_id = reserved_agent_id.to_s.freeze
        self
      end

      # @api private
      def __bind_runtime_owner!(runtime)
        unless @_phronomy_runtime_owner.equal?(runtime) &&
            @_phronomy_runtime_owner_state == :constructing
          raise Phronomy::Error, "Agent Runtime ownership construction state is invalid"
        end
        @_phronomy_runtime_owner_state = :live
        remove_instance_variable(:@_phronomy_reserved_agent_id) if
          instance_variable_defined?(:@_phronomy_reserved_agent_id)
        self
      end

      # @api private
      def __mark_purging!(runtime)
        unless @_phronomy_runtime_owner.equal?(runtime) &&
            @_phronomy_runtime_owner_state == :live
          raise Phronomy::Error, "Agent Runtime ownership purge state is invalid"
        end
        @_phronomy_runtime_owner_state = :purging
        self
      end

      # @api private
      def __restore_live_after_purge_abort!(runtime)
        unless @_phronomy_runtime_owner.equal?(runtime) &&
            @_phronomy_runtime_owner_state == :purging
          raise Phronomy::Error, "Agent Runtime ownership purge rollback state is invalid"
        end
        @_phronomy_runtime_owner_state = :live
        self
      end

      # @api private
      def __mark_ownership_recovery_required!(runtime)
        unless @_phronomy_runtime_owner.equal?(runtime) &&
            %i[constructing purging].include?(@_phronomy_runtime_owner_state)
          raise Phronomy::Error, "Agent Runtime ownership recovery state is invalid"
        end
        @_phronomy_runtime_owner_state = :recovery_required
        self
      end

      # @api private
      def __mark_purged!(runtime)
        unless @_phronomy_runtime_owner.equal?(runtime) &&
            @_phronomy_runtime_owner_state == :purging
          raise Phronomy::Error, "Agent Runtime ownership purge completion state is invalid"
        end
        @root = nil
        @_phronomy_journal_records = [].freeze
        @_phronomy_runtime_owner_state = :purged
        self
      end

      # @api private
      def __release_runtime_owner!(runtime)
        return self if @_phronomy_runtime_owner_state == :purged
        return self unless @_phronomy_runtime_owner.equal?(runtime)

        @_phronomy_runtime_owner_state = :released
        self
      end

      public

      # Internal EventLoop apply hook used only after a successful durable
      # operation result has been validated by ExecutionCoordinator.
      def __replace_root(root)
        @root = root
      end

      private

      attr_reader :_phronomy_event_listener

      def initialize_owned_state(
        agent_id:,
        context:,
        knowledge:,
        persistence:,
        metadata:,
        load_existing:
      )
        @persistence = persistence ||
          Phronomy.configuration.persistence ||
          Phronomy::Persistence::InMemory.new
        @agent_id = agent_id.to_s.freeze

        if load_existing
          root = records = nil
          @persistence.transaction do |tx|
            root = tx.agents.load(@agent_id)
            records = tx.journals.read(
              @agent_id,
              limit: root.journal_position
            )
          end
          validate_loaded_definition!(root)
          @root = root
          @_phronomy_journal_records = Array(records).dup.freeze
        else
          @root = create_agent_root!(
            context: context,
            knowledge: knowledge,
            metadata: metadata
          )
          @_phronomy_journal_records = @persistence.journals.read(
            @agent_id,
            limit: @root.journal_position
          ).dup.freeze
        end
      end

      def validate_loaded_definition!(loaded)
        definition = self.class.agent_definition
        return if current_definition_compatible?(loaded, definition)

        raise Phronomy::ConfigurationError,
          "Agent definition mismatch for #{@agent_id}: stored " \
          "#{loaded.agent_definition_id}@#{loaded.agent_definition_version}, runtime " \
          "#{definition.fetch(:id)}@#{definition.fetch(:version)}"
      end

      def current_definition_compatible?(loaded, runtime_definition)
        loaded.agent_definition_id == runtime_definition.fetch(:id) &&
          loaded.agent_definition_version == runtime_definition.fetch(:version)
      end

      def create_agent_root!(context:, knowledge:, metadata:)
        definition = self.class.agent_definition
        root = Agent::AgentRoot.create(
          agent_id: agent_id,
          agent_definition_id: definition.fetch(:id),
          agent_definition_version: definition.fetch(:version),
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
        __assert_live_agent!
        current = agent_root
        next_root = nil
        appended = nil
        persistence.transaction do |tx|
          tx.executions.assert_idle!(agent_id)
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
          tx.agents.save(
            agent_id,
            expected_revision: current.agent_revision,
            root: next_root
          )
        end
        _append_journal_records(appended)
        @root = next_root
      end

      def yield_context_revision(current, proposed)
        (proposed.context_revision == current.context_revision) ?
          current.context_revision + 1 : proposed.context_revision
      end

      def _journal_records_snapshot
        @_phronomy_journal_records || [].freeze
      end

      def _append_journal_records(records)
        incoming = Array(records)
        return _journal_records_snapshot if incoming.empty?

        @_phronomy_journal_records =
          (_journal_records_snapshot + incoming).freeze
      end

      public

      def tool_approval_policy(&block)
        __assert_live_agent!
        raise ArgumentError, "tool_approval_policy requires a block" unless block

        _approval_configuration_mutex.synchronize { @tool_approval_policy = block }
        self
      end

      private

      def __assert_agent_accessible!
        case @_phronomy_runtime_owner_state
        when :constructing, :live
          true
        when :purged
          raise Phronomy::AgentPurgedError, "Agent #{agent_id.inspect} has been purged"
        when :purging
          raise Phronomy::Error, "Agent #{agent_id.inspect} is being purged"
        when :recovery_required
          raise Phronomy::Error,
            "Agent #{agent_id.inspect} ownership requires durable recovery/reconciliation"
        else
          raise Phronomy::RuntimeShutdownError,
            "Agent #{agent_id.inspect} is detached from its Runtime"
        end
      end

      def __assert_live_agent!
        __assert_agent_accessible!
        return true if @_phronomy_runtime_owner_state == :constructing

        runtime = @_phronomy_runtime_owner
        unless runtime&.__agent_owned?(self)
          raise Phronomy::RuntimeShutdownError,
            "Agent #{agent_id.inspect} is no longer the live owner in its Runtime"
        end
        true
      end

      def _prepare_invocation_config(config, invocation_context)
        __assert_live_agent!
        _reject_removed_generic_identity_keys!(config)
        effective_config = invocation_context ?
          config.merge(invocation_context: invocation_context) : config

        if invocation_context && effective_config[:cancellation_token].nil?
          if (tok = invocation_context.effective_timeout_token)
            effective_config = effective_config.merge(
              cancellation_token: tok,
              phronomy_timeout_deadline: invocation_context.deadline
            )
          end
        end
        effective_config
      end

      def _reject_removed_generic_identity_keys!(config)
        removed_key = [
          :thread_id, "thread_id",
          :session_id, "session_id",
          :agent_invocation_id, "agent_invocation_id"
        ].find { |key| config.key?(key) }
        return unless removed_key

        raise ArgumentError,
          "Agent identity #{removed_key.inspect} was removed; " \
          "use purpose-specific domain identifiers or application tracing metadata"
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

      def _report_stream_callback_error(callback_error, event:, execution_id:,
        callback_error_policy:)
        lines = [
          "[Phronomy] Stream callback failed",
          "event=#{event.type.inspect}",
          "execution_id=#{execution_id || "unknown"}",
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
        custom_async_call =
          resolved.instance_method(:call_async).owner !=
          Phronomy::Agent::Context::Capability::Base

        Class.new(resolved) do
          tool_name effective_name
          define_method(:call) do |args, **kwargs|
            result = super(args, **kwargs)
            result_filters.inject(result) { |val, filter|
              filter.call(val, tool_name: name, args: args)
            }
          end

          if custom_async_call
            define_method(:call_async) do |args, **kwargs|
              source = super(args, **kwargs)
              filtered = Phronomy::Concurrency::PhysicalCompletionTask.deferred(
                name: "tool-filter-#{name}"
              )
              source_has_physical_signal = source.respond_to?(:on_physical_complete)
              source.on_physical_complete { filtered.mark_physical_complete! } if
                source_has_physical_signal
              source.on_complete do |value, error|
                if error
                  filtered.mark_physical_complete! unless source_has_physical_signal
                  if source.respond_to?(:status) && source.status == :cancelled
                    filtered.cancel!(error)
                  else
                    filtered.fail(error)
                  end
                  next
                end

                begin
                  result = result_filters.inject(value) { |val, filter|
                    filter.call(val, tool_name: name, args: args)
                  }
                  filtered.mark_physical_complete! unless source_has_physical_signal
                  filtered.complete(result)
                rescue => filter_error
                  filtered.mark_physical_complete! unless source_has_physical_signal
                  filtered.fail(filter_error)
                end
              end
              filtered
            end
          end
        end
      end
    end
  end
end
