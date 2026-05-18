# frozen_string_literal: true

module Phronomy
  module Agent
    # Implements the "Shared state" coordination pattern (Anthropic blog, Pattern 5).
    #
    # Multiple peer researcher agents collaborate through a shared {KnowledgeStore}.
    # There is no central coordinator. Each agent reads the store, acts on what it
    # finds, and writes new findings back. Later agents in a cycle immediately see
    # findings written by earlier agents in the same cycle.
    #
    # Two tools are automatically injected into every researcher agent at runtime:
    # - +read_store+    — returns all current findings as a JSON string
    # - +write_finding+ — appends a Hash finding to the store
    #
    # @example Basic usage
    #   class ResearchTeam < Phronomy::Agent::SharedState
    #     researchers LiteratureAgent, IndustryAgent, PatentAgent
    #     max_cycles  3
    #     aggregate   { |store| { findings: store.read_all, total: store.size } }
    #   end
    #
    #   result = ResearchTeam.new.invoke("Trends in quantum computing")
    #   # => { output: { findings: [...], total: N }, cycles: 2, terminated_by: :max_cycles }
    #
    # @example With convergence check
    #   class ResearchTeam < Phronomy::Agent::SharedState
    #     researchers LiteratureAgent, IndustryAgent
    #     max_cycles  10
    #     timeout     120
    #     terminate_when { |store| store.size >= 20 }
    #   end
    class SharedState
      # Thread-safe (serialised by sequential execution) knowledge store shared
      # across all researcher agents within a single {SharedState#invoke} call.
      #
      # Each finding is stored as a Hash with the keys:
      #   :agent   — Symbol derived from the researcher class name
      #   :content — String written by the researcher
      #   :cycle   — Integer cycle number in which the finding was recorded
      class KnowledgeStore
        def initialize
          @findings = []
        end

        # Returns a shallow copy of all findings in insertion order.
        # @return [Array<Hash>]
        def read_all
          @findings.dup
        end

        # Appends a new finding to the store.
        # @param agent   [Symbol]  researcher identifier
        # @param content [String]  the finding text
        # @param cycle   [Integer] the current cycle number
        # @return [nil]
        def write(agent:, content:, cycle:)
          @findings << {agent: agent, content: content, cycle: cycle}
          nil
        end

        # Returns the number of findings recorded so far.
        # @return [Integer]
        def size
          @findings.size
        end
      end

      class << self
        # Declares the researcher agent classes that will collaborate via the store.
        # Agents are invoked sequentially within each cycle in declaration order.
        #
        # @param classes [Array<Class>] Agent::Base subclasses
        def researchers(*classes)
          @researchers = classes.flatten
        end

        # Sets the maximum number of cycles to run.
        # At least one of +max_cycles+ or +timeout+ must be configured.
        #
        # @param value [Integer, nil]
        def max_cycles(value = nil)
          value ? @max_cycles = Integer(value) : @max_cycles
        end

        # Sets the maximum wall-clock seconds for the entire invocation.
        # At least one of +max_cycles+ or +timeout+ must be configured.
        #
        # @param value [Numeric, nil]
        def timeout(value = nil)
          value ? @timeout = value.to_f : @timeout
        end

        # Registers an optional convergence block. Evaluated after each completed
        # cycle; when it returns +true+ the loop terminates early.
        #
        # @yield [KnowledgeStore] receives the store; return +true+ to stop
        def terminate_when(&block)
          block ? @terminate_when = block : @terminate_when
        end

        # Defines how the final store is converted into the +:output+ of the result.
        # When omitted, +store.read_all+ is used as-is.
        #
        # @yield [KnowledgeStore] receives the final store; return value becomes +:output+
        def aggregate(&block)
          block ? @aggregator = block : @aggregator
        end

        # @!visibility private
        def _researchers = Array(@researchers)
        # @!visibility private
        def _max_cycles = @max_cycles
        # @!visibility private
        def _timeout = @timeout
        # @!visibility private
        def _terminate_when = @terminate_when
        # @!visibility private
        def _aggregator = @aggregator
      end

      # Runs the shared-state coordination loop.
      #
      # @param input  [String] the seed question or task description
      # @param config [Hash]   reserved for future use
      # @return [Hash] +:output+, +:cycles+, +:terminated_by+
      # @raise [ArgumentError] when neither +max_cycles+ nor +timeout+ is configured
      def invoke(input, config: {})
        validate_termination!

        store = KnowledgeStore.new
        max_cycles = self.class._max_cycles
        deadline   = self.class._timeout ? Time.now + self.class._timeout : nil
        terminated_by = :max_cycles
        completed_cycles = 0

        cycle_limit = max_cycles || Float::INFINITY

        (1..cycle_limit).each do |cycle|
          self.class._researchers.each do |researcher_class|
            invoke_researcher(researcher_class, store, cycle, input)
          end
          completed_cycles = cycle

          if self.class._terminate_when&.call(store)
            terminated_by = :terminate_when
            break
          end

          if deadline && Time.now >= deadline
            terminated_by = :timeout
            break
          end

          terminated_by = :max_cycles
        end

        output = if self.class._aggregator
          self.class._aggregator.call(store)
        else
          store.read_all
        end

        {output: output, cycles: completed_cycles, terminated_by: terminated_by}
      end

      private

      def validate_termination!
        return if self.class._max_cycles || self.class._timeout
        raise ArgumentError,
          "max_cycles or timeout must be configured before invoking SharedState"
      end

      # Invokes a single researcher agent for one cycle.
      # Builds an anonymous subclass of the researcher with +read_store+ and
      # +write_finding+ tools injected, then calls +invoke+ with a prompt that
      # includes the current store contents.
      def invoke_researcher(researcher_class, store, cycle, original_input)
        instrumented = build_instrumented_researcher(researcher_class, store, cycle)
        prompt = build_prompt(original_input, store, cycle)
        instrumented.new.invoke(prompt)
      end

      # Builds an anonymous subclass of +researcher_class+ with two store tools
      # injected. The tools close over the +store+ instance so that writes and
      # reads are reflected in the live store.
      def build_instrumented_researcher(researcher_class, store, cycle)
        agent_key = researcher_class.name&.to_sym || researcher_class.object_id.to_s.to_sym

        read_tool = Class.new(Phronomy::Tool::Base) do
          tool_name "read_store"
          description "Read all current findings from the shared knowledge store. " \
                      "Call this to see what other researchers have discovered."

          define_method(:execute) { store.read_all.to_json }
        end

        write_tool = Class.new(Phronomy::Tool::Base) do
          tool_name "write_finding"
          description "Record a new finding into the shared knowledge store so " \
                      "that other researchers can build on your discovery."
          param :content, type: :string, desc: "The finding to record"

          define_method(:execute) do |content:|
            store.write(agent: agent_key, content: content, cycle: cycle)
            "Finding recorded."
          end
        end

        Class.new(researcher_class) { tools read_tool, write_tool }
      end

      # Builds the invocation prompt for a researcher agent.
      # Cycle 1 uses the raw input; subsequent cycles prepend a summary of the
      # current store so the agent can build on prior findings.
      def build_prompt(original_input, store, cycle)
        return original_input if cycle == 1 || store.size == 0

        findings_text = store.read_all
          .map { |f| "- [#{f[:agent]} / cycle #{f[:cycle]}] #{f[:content]}" }
          .join("\n")

        "#{original_input}\n\nFindings so far:\n#{findings_text}"
      end
    end
  end
end
