# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Base class for orchestrator agents that coordinate multiple subagents.
    class Orchestrator < Agent::Base
      agent_definition id: "orchestrator", version: 1

      ParallelChild = Data.define(:index, :agent_class, :input, :config, :knowledge)
      private_constant :ParallelChild

      # Keeps exact child owners when safe release fails. The caller can finish
      # approval/recovery or retry unload without repeating the dispatched work.
      # @api public
      class ChildCleanupError < Phronomy::Error
        # @api public
        attr_reader :failures, :result, :primary_error

        # @api public
        def initialize(failures:, result: nil, primary_error: nil)
          @failures = failures.map { |failure| failure.dup.freeze }.freeze
          @result = result
          @primary_error = primary_error
          ids = @failures.map { |failure| failure.fetch(:agent).agent_id }
          super("Orchestrator could not release children #{ids.inspect}", code: "multi_agent.child_cleanup_failed")
        end
      end

      attr_reader :coordination_store

      def self.create(coordination_store: nil, **options, &block)
        new(coordination_store: coordination_store, **options, &block)
      end

      def self.load(agent_id, persistence:, coordination_store:, **options, &block)
        participant = DurableSubagentCoordinator.new(agent_class: self, persistence: coordination_store)
        super(agent_id, persistence: persistence, execution_wiring: {phronomy_execution_participant: participant}, **options, &block)
      end

      # Preserve native child ownership when explicitly replacing the Tool map.
      # Ordinary subclass inheritance still starts with no subagent registrations.
      def self.with_tools(definitions, id:, version:)
        derived = super
        retained = _subagent_tool_classes & derived.tools
        registrations = registered_subagents.select do |name, _|
          retained.any? { |tool| tool.tool_name == "dispatch_to_#{name}" }
        end.transform_values(&:dup)
        derived.instance_variable_set(:@_subagent_tool_classes, retained)
        derived.instance_variable_set(:@registered_subagents, registrations)
        derived
      end

      def initialize(coordination_store: nil, execution_wiring: {}, **options, &block)
        @coordination_store = coordination_store || execution_wiring[:phronomy_execution_participant]&.persistence || Phronomy::MultiAgent::Store.configured
        super(execution_wiring: execution_wiring, **options, &block)
        if @coordination_store && !@coordination_store.agent_store.equal?(persistence)
          raise Phronomy::ConfigurationError, "Orchestrator stores must share the same Agent store"
        end
        @participant = @coordination_store && DurableSubagentCoordinator.new(agent_class: self.class, persistence: @coordination_store)
      end

      # Release the local parent and its directly dispatched child after import
      # or terminal-parent acknowledgement. The stored history remains intact.
      # @api public
      def unload_with_completed_child!(parent_execution_id, execution_id:)
        owner = {"kind" => "subagent", "parent_agent_id" => agent_id, "parent_execution_id" => parent_execution_id}
        __unload_with_peer_execution!(execution_id, reserved_by: owner) do |child, live_child, scope|
          @participant&.completed_child_pair?(agent_id, parent_execution_id, child, live_child: live_child, scope: scope)
        end
      end

      # Current composition, never serialized in an execution record.
      def __invocation_config(config)
        if !self.class.registered_subagents.empty? && !@participant
          raise Phronomy::ConfigurationError, "Durable subagents require coordination_store:"
        end
        config.merge(cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new,
          phronomy_execution_participant: @participant).compact
      end

      # Answers the current wait of a recovered direct child. If the same
      # execution suspends again the host can release the pair with this handle.
      # @api public
      def approve_hosted_child(parent_execution_id, execution_id:, approval_request_id:, approved: true, config: {})
        resume_hosted_child_approval(parent_execution_id, execution_id: execution_id,
          approval_request_id: approval_request_id, approved: approved, config: config)
      end

      def self.subagent(name, agent_class, on_error: :raise, inherit_knowledge: true)
        # A subagent Tool is logically asynchronous: ToolInvocation starts the
        # child Agent and resumes when its completion TaskResult settles. It must not
        # occupy an OffloadPool worker while waiting for the child.
        tool_class = Class.new(Phronomy::Tool::Base) do
          execution_mode :cooperative
          param :input, type: :string, desc: "The input to forward to the wrapped Agent"
          def self.__framework_owned_operation? = true
          tool_name "dispatch_to_#{name}"
          description "Dispatch work to the #{name} subagent (#{agent_class.name})"

          attr_writer :_orchestrator_context

          define_method(:execute) do |input:, cancellation_token: nil|
            execute_async(
              input: input,
              cancellation_token: cancellation_token,
              config: {}
            ).wait_result
          end

          # Enter exact child reconciliation even when the parent token is
          # cancelled: an already admitted child must be settled, not forgotten.
          define_method(:call_async) do |args, cancellation_token: nil, config: {}|
            if @_orchestrator_context&.fetch(:parent, nil) && config[:phronomy_tool_invocation_id]
              validated, schema_error = validate_arguments(args)
              raise Phronomy::ToolError, schema_error if schema_error
              execute_async(**validated, cancellation_token: cancellation_token, config: config)
            else
              call_async_operation(args, cancellation_token: cancellation_token,
                operation_name: "agent-tool-#{self.name}") do |validated_args|
                execute_async(**validated_args, cancellation_token: cancellation_token, config: config || {})
              end
            end
          rescue => error
            Phronomy::TaskResult.failed(error, name: "subagent-dispatch-failed")
          end

          define_method(:execute_async) do |input:, cancellation_token: nil, config: {}|
            ctx = @_orchestrator_context || {}
            parent_ic = ctx[:invocation_context]
            task_config = (ctx[:config] || {}).merge(config || {})

            if cancellation_token && !task_config[:cancellation_token]
              task_config = task_config.merge(cancellation_token: cancellation_token)
            end

            if parent_ic && !task_config[:invocation_context]
              child_ic = parent_ic.merge(parent_task_id: parent_ic.task_id)
              task_config = task_config.merge(invocation_context: child_ic)
            end

            parent = ctx[:parent]
            if parent && task_config[:phronomy_tool_invocation_id]
              return DurableSubagentCoordinator.start(parent: parent,
                tool_invocation_id: task_config.fetch(:phronomy_tool_invocation_id),
                parent_execution_id: task_config.fetch(:execution_id), config: task_config)
            end
            agent = agent_class.new
            if inherit_knowledge
              Array(ctx[:knowledge]).each do |entry|
                agent.add_knowledge(entry.content, metadata: entry.metadata)
              end
            end
            Phronomy::AsyncOperation.call(name: "subagent-tool-#{name}",
              on_error: ->(error) { raise error if on_error == :raise },
              transform: ->(result) { result[:output] }) do
              agent.invoke_async(input, config: task_config)
            end
          rescue => error
            Phronomy::AsyncOperation.capture(name: "subagent-tool-#{name}",
              on_error: ->(failure) { raise failure if on_error == :raise }) { raise error }
          end
          # Recovery requirements retain their Agent meaning across delegation.
          def async_error_value(error)
            raise error if error.is_a?(Phronomy::ExecutionRehydrationRequiredError)

            super
          end
          private :execute_async, :async_error_value
        end

        @_subagent_tool_classes = (@_subagent_tool_classes || []) + [tool_class]
        @tools = (@tools || []) + [tool_class]
        @tool_aliases ||= {}
        registered_subagents[name] = {
          agent_class: agent_class,
          on_error: on_error,
          inherit_knowledge: inherit_knowledge
        }
      end

      def self._subagent_tool_classes
        @_subagent_tool_classes || []
      end

      def self.registered_subagents
        @registered_subagents ||= {}
      end

      # @api private
      def self.__subagent_tool_name(name)
        native_name = "dispatch_to_#{name}"
        tool = _subagent_tool_classes.find { |candidate| candidate.tool_name == native_name }
        tool && (tool_aliases[tool] || native_name)
      end

      def dispatch_parallel(
        *tasks,
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError,
            "dispatch_parallel cannot block the EventLoop; use dispatch_parallel_async"
        end
        dispatch_parallel_async(
          *tasks,
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context,
          inherit_knowledge: inherit_knowledge
        ).wait_result
      end

      def dispatch_parallel_async(
        *tasks,
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        validate_parallel_options!(tasks, max_concurrency, on_error)
        children = build_fan_out_children(tasks, inherit_knowledge: inherit_knowledge)
        retained = []
        retention_mutex = Mutex.new
        collecting = true
        keep_successful = false
        retain = ->(agent) {
          retention_mutex.synchronize do
            next false unless collecting
            retained << agent
            true
          end
        }
        execution = Phronomy::Execution.run_async(children,
          timeout: timeout, cancellation_token: cancellation_token,
          invocation_context: invocation_context, max_concurrency: max_concurrency) do |child, run|
          run.start_child(
            invocation_context: child.config[:invocation_context],
            cancellation_token: child.config[:cancellation_token],
            parent_task_id: invocation_context&.task_id
          ) do |child_context, token|
            invoke_direct_child_async(child, invocation_context: child_context,
              cancellation_token: token, retain: retain)
          end
        end
        Phronomy::AsyncOperation.finalize(name: "orchestrator-dispatch-release",
          cleanup: -> {
            owners = retention_mutex.synchronize do
              collecting = false
              retained.dup
            end
            if keep_successful
              owners.each { |agent| __execution_environment.ownership.cancel_expected_unload(agent) }
              Phronomy::TaskResult.completed(nil)
            else
              release_direct_children(owners)
            end
          },
          on_cleanup_error: ->(value, primary, cleanup) {
            failures = cleanup.is_a?(ChildCleanupError) ? cleanup.failures : retained.map { |agent| {agent: agent, error: cleanup} }
            child_cleanup_failed(value, primary, failures)
          }) do
          Phronomy::AsyncOperation.map(execution, name: "orchestrator-dispatch-results") do |outcomes|
            values = outcomes.map { |outcome| (outcome.status == :completed) ? outcome.value : nil }
            cleanup_failures = outcomes.flat_map do |outcome|
              outcome.error.is_a?(ChildCleanupError) ? outcome.error.failures : []
            end
            failure = outcomes.find { |outcome| outcome.status != :completed }
            unless cleanup_failures.empty?
              primary = failure.error.is_a?(ChildCleanupError) ? failure.error.primary_error : failure.error
              raise ChildCleanupError.new(failures: cleanup_failures, result: values, primary_error: primary), cause: primary
            end
            raise failure.error if failure && on_error == :raise

            keep_successful = true
            values
          end
        end
      end

      def subagent(
        agent_class,
        input,
        config: nil,
        inherit_knowledge: true
      )
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError,
            "subagent cannot block the EventLoop; use the async Agent API"
        end
        task = {agent: agent_class, input: input, config: config || {}}
        validate_parallel_options!([task], nil, :raise)
        child = build_fan_out_children([task], inherit_knowledge: inherit_knowledge).first
        invoke_direct_child_async(child, invocation_context: nil, cancellation_token: nil,
          retain: ->(agent) { __execution_environment.ownership.cancel_expected_unload(agent) }).wait_result
      end

      # @api private
      def __framework_tool_replayable?(name)
        self.class.registered_subagents.keys.any? { |key| self.class.__subagent_tool_name(key) == name.to_s }
      end

      private

      def hosted_child_approval_reader = @participant&.method(:child_approval_wait)

      def prepare_tool_class(tool_class, invocation: nil)
        prepared = super
        return prepared unless self.class._subagent_tool_classes.include?(tool_class)

        subagent_name = tool_class.tool_name.delete_prefix("dispatch_to_")
        registration = self.class.registered_subagents.find do |name, _|
          name.to_s == subagent_name
        end&.last
        inherits_knowledge = registration ? registration.fetch(:inherit_knowledge, true) : true

        context = {parent: self}
        # Invocation-owned Tools inherit the durable child slot's knowledge,
        # captured by the existing preparation transaction off EventLoop.
        context[:knowledge] = active_knowledge_snapshot if inherits_knowledge && !invocation
        if invocation
          context[:config] = invocation.config
          context[:invocation_context] = invocation.config[:invocation_context]
        end

        # Cached Tool methods can outlive an execution. Only the instance used
        # for this dispatch should hold its parent and invocation configuration.
        tool = prepared.new
        tool._orchestrator_context = context.freeze
        tool
      end

      def active_knowledge_snapshot = knowledge_snapshot

      def validate_parallel_options!(tasks, max_concurrency, on_error)
        unless %i[raise skip].include?(on_error)
          raise ArgumentError, "unknown on_error: #{on_error.inspect}"
        end
        if max_concurrency && !(max_concurrency.is_a?(Integer) && max_concurrency.positive?)
          raise ArgumentError, "max_concurrency must be a positive Integer"
        end
        tasks.each do |task|
          raise ArgumentError, "fan-out task must be a Hash" unless task.is_a?(Hash)
          raise ArgumentError, "fan-out task requires :agent" unless task[:agent]
          raise ArgumentError, "fan-out task requires :input" unless task.key?(:input)
          unless task.fetch(:config, {}).is_a?(Hash)
            raise ArgumentError, "fan-out task :config must be a Hash"
          end
          if task.key?(:thread_id) || task.key?("thread_id")
            raise ArgumentError,
              "fan-out task generic thread_id was removed; " \
              "use purpose-specific domain identifiers or application tracing metadata"
          end
          _reject_removed_generic_identity_keys!(task.fetch(:config, {}))
        end
      end

      def build_fan_out_children(tasks, inherit_knowledge:)
        inheritance_flags = tasks.map { |task| task.fetch(:inherit_knowledge, inherit_knowledge) }
        knowledge_snapshot = active_knowledge_snapshot if inheritance_flags.any?

        tasks.each_with_index.map do |task, index|
          task_config = task.fetch(:config, {}).dup
          ParallelChild.new(
            index: index,
            agent_class: task.fetch(:agent),
            input: task.fetch(:input),
            config: task_config,
            knowledge: inheritance_flags[index] ? knowledge_snapshot : []
          )
        end
      end

      # Only admitted JOBs materialize owners. Construction and knowledge I/O
      # stay off EventLoop; the finalizer waits for their physical completion.
      def invoke_direct_child_async(child, invocation_context:, cancellation_token:, retain:)
        agent = nil
        successful = false
        environment = __execution_environment
        # Preparation can fail before invoke initializes its executor. Establish
        # the existing release path before any child becomes an accepted owner.
        environment.registry
        ownership = environment.ownership
        Phronomy::AsyncOperation.finalize(name: "orchestrator-child-release",
          cleanup: -> {
            if !agent || (successful && retain.call(agent))
              Phronomy::TaskResult.completed(nil)
            else
              agent.unload_async
            end
          },
          on_cleanup_error: ->(value, primary, cleanup) {
            ownership.cancel_expected_unload(agent)
            child_cleanup_failed(value, primary, [{agent: agent, error: cleanup}])
          }) do
          materialized = environment.submit(on_full: :raise) do
            agent = child.agent_class.new
            ownership.expect_unload(agent)
            child.knowledge.each { |entry| agent.add_knowledge(entry.content, metadata: entry.metadata) }
            agent
          end
          materialized.flat_map do |owner|
            config = cancellation_token ? child.config.merge(cancellation_token: cancellation_token) : child.config
            Phronomy::AsyncOperation.call(name: "orchestrator-child-invoke",
              transform: ->(value) {
                successful = true
                value
              }) do
              owner.invoke_async(child.input, config: config, invocation_context: invocation_context)
            end
          end
        end
      end

      def release_direct_children(agents)
        released = Phronomy::TaskResult.all_settled(agents.map(&:unload_async))
        Phronomy::AsyncOperation.map(released, name: "orchestrator-unreturned-children") do |outcomes|
          failures = outcomes.filter_map do |outcome|
            next if outcome.status == :completed
            agent = agents.fetch(outcome.index)
            __execution_environment.ownership.cancel_expected_unload(agent)
            {agent: agent, error: outcome.error}
          end
          raise ChildCleanupError.new(failures: failures) unless failures.empty?
        end
      end

      def child_cleanup_failed(result, primary, failures)
        failures = primary.failures + failures if primary.is_a?(ChildCleanupError)
        error = ChildCleanupError.new(failures: failures, result: result, primary_error: primary)
        begin
          details = failures.map { |failure| {agent_id: failure.fetch(:agent).agent_id, error: Phronomy::Error.diagnostic(failure.fetch(:error))} }
          message = "[Phronomy] Orchestrator child cleanup failed: #{details.inspect}"
          logger = Phronomy::RuntimeSettings.current.logger
          logger ? logger.error(message) : warn(message)
        rescue
          # A cancelled observer must not hide retained owners; diagnostic errors
          # cannot replace the original cleanup result or retry business work.
          nil
        end
        raise error, cause: primary || failures.first.fetch(:error)
      end
    end
  end
end
