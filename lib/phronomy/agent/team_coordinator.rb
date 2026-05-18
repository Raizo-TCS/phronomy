# frozen_string_literal: true

module Phronomy
  module Agent
    # Implements the "Agent teams" coordination pattern (Anthropic blog, Pattern 3).
    #
    # A coordinator LLM agent decomposes work into tasks and enqueues them
    # dynamically via built-in tools. A fixed pool of worker agents claims tasks
    # from the shared queue, carrying forward their conversation history across
    # assignments to accumulate domain context over time.
    #
    # The coordinator is an {Agent::Base} subclass that has two built-in tools:
    # - +enqueue_task+ — adds a task description to the queue
    # - +finalize+     — signals that all tasks have been enqueued
    #
    # Worker persistence is implemented by passing each worker's accumulated
    # +messages+ array back via +config[:messages]+ on every subsequent +invoke+
    # call, so the LLM retains context across multiple task assignments.
    #
    # @example Basic usage
    #   class MigrationTeam < Phronomy::Agent::TeamCoordinator
    #     coordinator_model        "claude-3-5-sonnet-20241022"
    #     coordinator_instructions <<~INST
    #       Analyze the request and enqueue one migration task per service.
    #       Call enqueue_task for each service, then call finalize.
    #     INST
    #
    #     pool size: 3, agent: MigrationAgent
    #
    #     aggregate do |assignments|
    #       { reports: assignments.map { |a| { task: a[:task][:description], result: a[:result] } } }
    #     end
    #   end
    #
    #   result = MigrationTeam.new.invoke("Migrate all services to Rails 8")
    class TeamCoordinator
      # Holds per-worker context between task invocations.
      # Worker persistence is implemented by carrying +messages+ forward on each
      # successive +agent#invoke+ call via +config[:messages]+.
      WorkerState = Struct.new(
        :index,    # Integer — 0-based worker index
        :agent,    # Agent::Base instance
        :messages, # Array  — accumulated conversation history
        :status,   # Symbol — :idle | :available | :done
        keyword_init: true
      ) do
        # Returns true when this worker is ready to accept the next task.
        def available? = [:idle, :available].include?(status)
      end
      private_constant :WorkerState

      class << self
        # Sets the LLM model for the coordinator agent.
        # Falls back to +Phronomy.configuration.default_model+ when not set.
        #
        # @param value [String, nil]
        def coordinator_model(value = nil)
          value ? @coordinator_model = value : @coordinator_model
        end

        # Sets the system instructions for the coordinator agent.
        # The prompt should direct the LLM to call +enqueue_task+ for each task
        # and then call +finalize+ when all tasks are enqueued.
        #
        # @param value [String, nil]
        def coordinator_instructions(value = nil)
          value ? @coordinator_instructions = value : @coordinator_instructions
        end

        # Configures the worker pool.
        #
        # @param size     [Integer] number of persistent worker instances
        # @param agent    [Class]   Agent::Base subclass used for all workers
        # @param on_error [Symbol]  +:raise+ (default) propagates worker exceptions;
        #                           +:skip+ records the failure and continues with remaining tasks
        def pool(size:, agent:, on_error: :raise)
          @pool_size = Integer(size)
          @worker_agent = agent
          @on_error = on_error
        end

        # Customises the worker selection algorithm.
        # The block receives an Array of available WorkerState objects and must
        # return the one to assign the next task to.
        # Default: worker with the fewest accumulated messages (round-robin-like).
        #
        # @yield [Array<WorkerState>] available workers
        # @yieldreturn [WorkerState] the chosen worker
        def schedule(&block)
          @scheduler = block
        end

        # Defines how task assignments are merged into the final return value.
        # The block receives an Array of assignment Hashes:
        #   { task: Hash, result: String|nil, worker: Integer, error: Exception|nil }
        # When omitted, the raw assignments array is returned.
        #
        # @yield [Array<Hash>] all completed (and skipped) task assignments
        def aggregate(&block)
          @aggregator = block
        end

        # @!visibility private
        def _coordinator_model = @coordinator_model
        # @!visibility private
        def _coordinator_instructions = @coordinator_instructions
        # @!visibility private
        def _pool_size = @pool_size || 1
        # @!visibility private
        def _worker_agent = @worker_agent
        # @!visibility private
        def _on_error = @on_error || :raise
        # @!visibility private
        def _scheduler = @scheduler
        # @!visibility private
        def _aggregator = @aggregator
      end

      # Runs the full team coordination: coordinator generates tasks, workers
      # process them sequentially, and the aggregate block merges the results.
      #
      # @param team_input [String, Hash] the high-level objective given to the coordinator
      # @param config     [Hash]         reserved for future use
      # @return [Object] the return value of the aggregate block, or the raw assignments Array
      # @raise [ArgumentError] when +pool :agent+ has not been configured
      def invoke(team_input, config: {})
        raise ArgumentError, "pool :agent must be configured before invoking" unless self.class._worker_agent

        task_queue = []
        run_coordinator(team_input, task_queue)
        assignments = run_workers(task_queue)
        finalize_result(assignments)
      end

      # Streaming version of +invoke+. Yields a Hash event for each completed or
      # failed task assignment.
      #
      # Yielded Hash keys:
      #   :type   — +:task_completed+ or +:task_failed+
      #   :worker — worker index (Integer)
      #   :task   — the task Hash from the queue ({ id:, description:, metadata:, enqueued_at: })
      #   :result — output string, or +nil+ on failure
      #   :error  — Exception, or +nil+ on success
      #
      # @param team_input [String, Hash]
      # @param config     [Hash]
      # @yield [Hash] one event per completed/failed task
      # @return [Object] same as +invoke+
      # @raise [ArgumentError] when +pool :agent+ has not been configured
      def stream(team_input, config: {}, &block)
        return invoke(team_input, config: config) unless block

        raise ArgumentError, "pool :agent must be configured before invoking" unless self.class._worker_agent

        task_queue = []
        run_coordinator(team_input, task_queue)
        assignments = run_workers(task_queue, &block)
        finalize_result(assignments)
      end

      private

      # Phase 1: Run the coordinator LLM agent to populate task_queue.
      def run_coordinator(team_input, task_queue)
        coordinator = build_coordinator_agent(task_queue)
        input = team_input.is_a?(String) ? team_input : team_input.to_s
        coordinator.invoke(input)
      end

      # Phase 2: Process tasks from the queue using the worker pool.
      # Workers accumulate message history across assignments.
      def run_workers(task_queue, &event_block)
        pool_size = self.class._pool_size
        agent_class = self.class._worker_agent
        on_error = self.class._on_error
        scheduler = self.class._scheduler

        workers = Array.new(pool_size) do |i|
          WorkerState.new(index: i, agent: agent_class.new, messages: [], status: :idle)
        end

        assignments = []

        until task_queue.empty?
          task = task_queue.shift
          available = workers.select(&:available?)
          worker = scheduler ? scheduler.call(available) : default_scheduler(available)

          begin
            result = worker.agent.invoke(task[:description], config: {messages: worker.messages})
            worker.messages = result[:messages]
            worker.status = :available
            entry = {task: task, result: result[:output], worker: worker.index, error: nil}
            assignments << entry
            event_block&.call(entry.merge(type: :task_completed))
          rescue => e
            worker.status = :available
            raise unless on_error == :skip

            entry = {task: task, result: nil, worker: worker.index, error: e}
            assignments << entry
            event_block&.call(entry.merge(type: :task_failed))
          end
        end

        workers.each { |w| w.status = :done }
        assignments
      end

      # Phase 3: Apply the aggregate block (or return raw assignments).
      def finalize_result(assignments)
        aggregator = self.class._aggregator
        aggregator ? aggregator.call(assignments) : assignments
      end

      # Default scheduler: assign to the worker with the fewest accumulated
      # messages (promotes round-robin-like distribution across the pool).
      def default_scheduler(available_workers)
        available_workers.min_by { |w| w.messages.size }
      end

      # Build an anonymous coordinator Agent::Base with the two built-in tools.
      def build_coordinator_agent(task_queue)
        coordinator_model_val = self.class._coordinator_model
        coordinator_instructions_val = self.class._coordinator_instructions
        enqueue_tool = build_enqueue_tool(task_queue)
        finalize_tool = build_finalize_tool(task_queue)

        coordinator_class = Class.new(Phronomy::Agent::Base) do
          model coordinator_model_val
          instructions coordinator_instructions_val
          tools enqueue_tool, finalize_tool
        end

        coordinator_class.new
      end

      # Builds the +enqueue_task+ tool. Each call appends a task Hash to task_queue.
      def build_enqueue_tool(task_queue)
        Class.new(Phronomy::Tool::Base) do
          tool_name "enqueue_task"
          description "Add a task to the worker queue."
          param :description, type: :string, desc: "What the worker agent should do"
          param :metadata, type: :string, desc: "Optional metadata", required: false

          define_method(:execute) do |description:, metadata: nil|
            task = {id: task_queue.size + 1, description: description, metadata: metadata, enqueued_at: Time.now}
            task_queue << task
            "Task ##{task[:id]} enqueued: #{description}"
          end
        end
      end

      # Builds the +finalize+ tool. Signals to the coordinator LLM that all tasks
      # have been enqueued; returns a confirmation string.
      def build_finalize_tool(task_queue)
        Class.new(Phronomy::Tool::Base) do
          tool_name "finalize"
          description "Signal that task generation is complete. Call this after all tasks have been enqueued."
          param :summary, type: :string, desc: "Brief summary of what was enqueued", required: false

          define_method(:execute) do |summary: ""|
            "Finalized. #{task_queue.size} task(s) enqueued. #{summary}".strip
          end
        end
      end
    end
  end
end
