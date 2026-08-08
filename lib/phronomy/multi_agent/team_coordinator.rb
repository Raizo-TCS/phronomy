# frozen_string_literal: true

require "securerandom"

module Phronomy
  module MultiAgent
    # Coordinator/worker multi-agent pattern with persistent worker Agent state.
    class TeamCoordinator
      WorkerState = Struct.new(
        :index,
        :agent,
        :transcript_size,
        :status
      ) do
        def available? = %i[idle available].include?(status)
      end
      private_constant :WorkerState

      class << self
        # @api public
        def coordinator_model(value = nil)
          value ? @coordinator_model = value : @coordinator_model
        end

        # @api public
        def coordinator_instructions(value = nil)
          value ? @coordinator_instructions = value : @coordinator_instructions
        end

        # @api public
        def coordinator_provider(value = nil)
          value ? @coordinator_provider = value : @coordinator_provider
        end

        # @api public
        def pool(size:, agent:, on_error: :raise)
          @pool_size = Integer(size)
          @worker_agent = agent
          @on_error = on_error
        end

        # @api public
        def schedule(&block)
          @scheduler = block
        end

        # @api public
        def aggregate(&block)
          @aggregator = block
        end

        def _coordinator_model = @coordinator_model
        def _coordinator_instructions = @coordinator_instructions
        def _coordinator_provider = @coordinator_provider
        def _pool_size = @pool_size || 1
        def _worker_agent = @worker_agent
        def _on_error = @on_error || :raise
        def _scheduler = @scheduler
        def _aggregator = @aggregator
      end

      # @api public
      def invoke(team_input, config: {})
        unless self.class._worker_agent
          raise ArgumentError, "pool :agent must be configured before invoking"
        end

        task_queue = []
        run_coordinator(team_input, task_queue)
        assignments = run_workers(task_queue)
        finalize_result(assignments)
      end

      # @api public
      def stream(team_input, config: {}, &block)
        return invoke(team_input, config: config) unless block

        unless self.class._worker_agent
          raise ArgumentError, "pool :agent must be configured before invoking"
        end

        task_queue = []
        run_coordinator(team_input, task_queue)
        assignments = run_workers(task_queue, &block)
        finalize_result(assignments)
      end

      private

      def run_coordinator(team_input, task_queue)
        coordinator = build_coordinator_agent(task_queue)
        input = team_input.is_a?(String) ? team_input : team_input.to_s
        coordinator.invoke(input)
      end

      def run_workers(task_queue, &event_block)
        pool_size = self.class._pool_size
        agent_class = self.class._worker_agent
        on_error = self.class._on_error
        scheduler = self.class._scheduler

        workers = Array.new(pool_size) do |index|
          WorkerState.new(
            index: index,
            agent: agent_class.new,
            transcript_size: 0,
            status: :idle
          )
        end

        assignments = []

        until task_queue.empty?
          task = task_queue.shift
          available = workers.select(&:available?)
          worker = scheduler ? scheduler.call(available) : default_scheduler(available)

          begin
            result = worker.agent.invoke(task[:description])
            worker.transcript_size = worker.agent.transcript.length
            worker.status = :available
            entry = {
              task: task,
              result: result[:output],
              worker: worker.index,
              error: nil
            }
            assignments << entry
            event_block&.call(entry.merge(type: :task_completed))
          rescue => error
            worker.status = :available
            raise unless on_error == :skip

            entry = {
              task: task,
              result: nil,
              worker: worker.index,
              error: error
            }
            assignments << entry
            event_block&.call(entry.merge(type: :task_failed))
          end
        end

        workers.each { |worker| worker.status = :done }
        assignments
      end

      def finalize_result(assignments)
        aggregator = self.class._aggregator
        aggregator ? aggregator.call(assignments) : assignments
      end

      def default_scheduler(available_workers)
        available_workers.min_by(&:transcript_size)
      end

      def build_coordinator_agent(task_queue)
        coordinator_model_val = self.class._coordinator_model
        coordinator_instructions_val = self.class._coordinator_instructions
        coordinator_provider_val = self.class._coordinator_provider
        enqueue_tool = build_enqueue_tool(task_queue)
        finalize_tool = build_finalize_tool(task_queue)

        coordinator_class = Class.new(Phronomy::Agent::Base) do
          agent_definition id: "team-coordinator-#{SecureRandom.hex(4)}", version: 1
          model coordinator_model_val
          provider coordinator_provider_val if coordinator_provider_val
          instructions coordinator_instructions_val
          tools(enqueue_tool => nil, finalize_tool => nil)
        end

        coordinator_class.new
      end

      def build_enqueue_tool(task_queue)
        Class.new(Phronomy::Agent::Context::Capability::Base) do
          tool_name "enqueue_task"
          description "Add a task to the worker queue."
          param :description, type: :string, desc: "What the worker agent should do"
          param :metadata, type: :string, desc: "Optional metadata", required: false

          define_method(:execute) do |description:, metadata: nil|
            task = {
              id: task_queue.size + 1,
              description: description,
              metadata: metadata,
              enqueued_at: Time.now
            }
            task_queue << task
            "Task ##{task[:id]} enqueued: #{description}"
          end
        end
      end

      def build_finalize_tool(task_queue)
        Class.new(Phronomy::Agent::Context::Capability::Base) do
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
