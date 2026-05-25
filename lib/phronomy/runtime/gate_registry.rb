# frozen_string_literal: true

module Phronomy
  class Runtime
    # Lazy cache of {ConcurrencyGate} instances, keyed by resource name.
    #
    # Gate concurrency caps are read from {Phronomy::Configuration} when a gate
    # is first accessed; subsequent calls return the cached instance.  Call
    # {#reset} to drop the cache and force a rebuild on the next access.
    # @api private
    class GateRegistry
      GATE_CONFIG_MAP = {
        agent: :max_concurrent_agent_tasks,
        tool: :max_concurrent_tool_tasks,
        workflow: :max_concurrent_workflow_tasks,
        llm: :max_concurrent_llm_calls,
        rag: :max_concurrent_rag_fetches,
        vector: :max_concurrent_vector_searches
      }.freeze
      private_constant :GATE_CONFIG_MAP

      def initialize
        @mutex = Mutex.new
        @gates = {}
      end

      # Returns (or lazily creates) the gate for +name+.
      # @param name [Symbol]
      # @return [ConcurrencyGate]
      # @api private
      def get(name)
        @mutex.synchronize { @gates[name] ||= _build(name) }
      end

      # Drops the cached gate for +name+ so the next {#get} rebuilds it.
      # @param name [Symbol]
      # @return [void]
      # @api private
      def reset(name)
        @mutex.synchronize { @gates.delete(name) }
      end

      private

      def _build(name)
        config_key = GATE_CONFIG_MAP[name]
        max = config_key ? Phronomy.configuration.public_send(config_key) : nil
        ConcurrencyGate.new(max_concurrent: max, name: name)
      end
    end
  end
end
