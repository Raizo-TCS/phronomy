# frozen_string_literal: true

module Phronomy
  module Agent
    # Implements the "Shared state" coordination pattern (Anthropic blog, Pattern 5).
    #
    # Multiple peer agents collaborate through a shared {KnowledgeStore}.
    # There is no central coordinator. Each agent reads the store, acts on what it
    # finds, and writes new findings back. Later agents in a cycle immediately see
    # findings written by earlier agents in the same cycle.
    #
    # Two tools are automatically injected into every member agent at runtime:
    # - +read_store+    — returns all current findings as a JSON string
    # - +write_finding+ — appends a Hash finding to the store
    #
    # Use +member+ to register agents and optionally provide per-agent coordination
    # instructions. Use +coordination+ to define the team-level protocol that all
    # members receive instead of the built-in default guide.
    #
    # @example Basic usage with per-agent instructions
    #   class CodeReviewTeam < Phronomy::Agent::SharedState
    #     member StructureAnalyst
    #     member SecurityAuditor, instruction: "Focus on authentication and injection risks."
    #     member QualityReviewer,  instruction: "Flag methods longer than 10 lines."
    #     max_cycles  3
    #     aggregate   { |store| { findings: store.read_all, total: store.size } }
    #   end
    #
    #   result = CodeReviewTeam.new.invoke("Review the files in ./src")
    #   # => { output: { findings: [...], total: N }, cycles: 3, terminated_by: :max_cycles }
    #
    # @example With custom team-level coordination protocol
    #   class ResearchTeam < Phronomy::Agent::SharedState
    #     coordination <<~TEXT
    #       Shared store tools: read_store (no params), write_finding(content:).
    #       Workflow: read first, then write one finding per insight.
    #     TEXT
    #     member LiteratureAgent
    #     member IndustryAgent
    #     max_cycles  10
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
        # Registers a member agent class that will collaborate via the shared store.
        # Members are invoked sequentially within each cycle in declaration order.
        #
        # @param klass [Class] an Agent::Base subclass
        # @param instruction [String, nil] optional per-agent coordination instruction
        #   appended to the team coordination text in this agent's prompt
        def member(klass, instruction: nil)
          @members ||= []
          @members << {klass: klass, instruction: instruction}
        end

        # Backward-compatible alias. Registers each class as a member without a
        # per-agent instruction. Prefer {.member} for new code.
        #
        # @param classes [Array<Class>] Agent::Base subclasses
        def researchers(*classes)
          classes.flatten.each { |klass| member(klass) }
        end

        # Defines the team-level coordination protocol text injected into every
        # member's prompt. When omitted the built-in default guide is used, which
        # explains +read_store+ / +write_finding+ usage and enforces the standard
        # workflow. Override this when you need a different protocol or tone.
        #
        # @param text [String, nil] the coordination instructions
        def coordination(text = nil)
          text ? @coordination = text : @coordination
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
        def _members = Array(@members)
        # @!visibility private — derives class list from _members for backward compat
        def _researchers = _members.map { |m| m[:klass] }
        # @!visibility private
        def _coordination = @coordination
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
        deadline = self.class._timeout ? Time.now + self.class._timeout : nil
        terminated_by = :max_cycles
        completed_cycles = 0

        cycle_limit = max_cycles || Float::INFINITY

        (1..cycle_limit).each do |cycle|
          self.class._members.each do |member_config|
            invoke_researcher(member_config[:klass], store, cycle, input, member_config[:instruction])
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

      # Invokes a single member agent for one cycle.
      # Builds an anonymous subclass with +read_store+ and +write_finding+ injected,
      # then calls +invoke+ with a prompt that includes the coordination guide,
      # any per-agent instruction, and the current store contents.
      def invoke_researcher(researcher_class, store, cycle, original_input, per_agent_instruction = nil)
        instrumented = build_instrumented_researcher(researcher_class, store, cycle)
        extra_tools = researcher_class.tools
        prompt = build_prompt(original_input, store, cycle,
          extra_tools: extra_tools,
          per_agent_instruction: per_agent_instruction)
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

        parent_tools = researcher_class.tools
        Class.new(researcher_class) { tools(*parent_tools, read_tool, write_tool) }
      end

      # Builds the invocation prompt for a member agent.
      # Uses the team-level coordination text when defined via {.coordination},
      # otherwise falls back to the built-in default guide. Appends any per-agent
      # instruction after the coordination text. Subsequent cycles also include
      # the current store contents so agents can build on prior findings.
      def build_prompt(original_input, store, cycle, extra_tools: [], per_agent_instruction: nil)
        guide = self.class._coordination || default_coordination_guide(extra_tools)

        prompt_parts = [guide]
        if per_agent_instruction
          prompt_parts << "\nYour specific focus for this session: #{per_agent_instruction}"
        end
        header = prompt_parts.join

        base = "#{header}\n\nTask: #{original_input}"
        return base if store.size == 0

        findings_text = store.read_all
          .map { |f| "- [#{f[:agent]} / cycle #{f[:cycle]}] #{f[:content]}" }
          .join("\n")

        "#{header}\n\nTask: #{original_input}\n\nFindings so far:\n#{findings_text}"
      end

      # Builds the default tool-usage guide for member agents.
      # Describes +read_store+ / +write_finding+ and the required workflow.
      # When extra_tools are present, lists their names so the agent knows
      # what additional tools are available.
      def default_coordination_guide(extra_tools)
        extra_line = if extra_tools.any?
          tool_names = extra_tools.map { |t| t.respond_to?(:tool_name) ? t.tool_name : t.name.to_s }.join(", ")
          "  You also have access to additional tools (#{tool_names}) — use them to gather information before writing findings.\n"
        else
          ""
        end

        <<~TEXT.chomp
          You have access to a shared knowledge store via two tools:
            read_store     — returns all current findings as JSON (no parameters)
            write_finding  — records one finding to the store (param: content)
          #{extra_line}Required workflow: first call read_store, then call write_finding once per insight.
          Each call to write_finding must contain exactly one unique insight — do not call it twice with the same content.
          If you have no new insights to contribute, call write_finding exactly once with: "No new findings in this cycle."
          Do not output plain text — every insight must be submitted via write_finding.
        TEXT
      end
    end
  end
end
