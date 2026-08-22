# frozen_string_literal: true

module Phronomy
  module Agent
    # Implements peer coordination through a shared KnowledgeStore.
    class SharedState
      # Semantic revision of the framework-owned SharedState instrumentation
      # applied on top of one specific researcher definition revision.
      #
      # The generated definition ID below already includes the wrapped
      # researcher's definition ID/version. Increment this value only when the
      # semantics of SharedState's injected coordination capabilities change.
      INSTRUMENTATION_DEFINITION_VERSION = 1
      private_constant :INSTRUMENTATION_DEFINITION_VERSION

      class KnowledgeStore
        def initialize
          @findings = []
        end

        # @api public
        def read_all
          @findings.dup
        end

        # @api public
        def write(agent:, content:, cycle:)
          @findings << {agent: agent, content: content, cycle: cycle}
          nil
        end

        # @api public
        def size
          @findings.size
        end
      end

      class << self
        # @api public
        def member(klass, instruction: nil)
          @members ||= []
          @members << {klass: klass, instruction: instruction}
        end

        # @api public
        def coordination(text = nil)
          text ? @coordination = text : @coordination
        end

        # @api public
        def max_cycles(value = nil)
          value ? @max_cycles = Integer(value) : @max_cycles
        end

        # @api public
        def timeout(value = nil)
          value ? @timeout = value.to_f : @timeout
        end

        # @api public
        def terminate_when(&block)
          block ? @terminate_when = block : @terminate_when
        end

        # @api public
        def aggregate(&block)
          block ? @aggregator = block : @aggregator
        end

        def _members = Array(@members)
        def _coordination = @coordination
        def _max_cycles = @max_cycles
        def _timeout = @timeout
        def _terminate_when = @terminate_when
        def _aggregator = @aggregator
      end

      # @api public
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
            invoke_researcher(
              member_config[:klass],
              store,
              cycle,
              input,
              member_config[:instruction]
            )
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

      def invoke_researcher(
        researcher_class,
        store,
        cycle,
        original_input,
        per_agent_instruction = nil
      )
        instrumented = build_instrumented_researcher(researcher_class, store, cycle)
        extra_tools = researcher_class.tools
        prompt = build_prompt(
          original_input,
          store,
          cycle,
          extra_tools: extra_tools,
          per_agent_instruction: per_agent_instruction
        )
        instrumented.new.invoke(prompt)
      end

      def build_instrumented_researcher(researcher_class, store, cycle)
        agent_key = researcher_class.name&.to_sym || researcher_class.object_id.to_s.to_sym

        read_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
          tool_name "read_store"
          description "Read all current findings from the shared knowledge store. " \
            "Call this to see what other researchers have discovered."
          execution_mode :cooperative

          define_method(:execute) { store.read_all.to_json }
        end

        write_tool = Class.new(Phronomy::Agent::Context::Capability::Base) do
          tool_name "write_finding"
          description "Record a new finding into the shared knowledge store so " \
            "that other researchers can build on your discovery."
          execution_mode :cooperative
          param :content, type: :string, desc: "The finding to record"

          define_method(:execute) do |content:|
            store.write(agent: agent_key, content: content, cycle: cycle)
            "Finding recorded."
          end
        end

        definitions = researcher_class.tools.to_h do |tool_class|
          [tool_class, researcher_class.tool_aliases[tool_class]]
        end
        definitions[read_tool] = nil
        definitions[write_tool] = nil

        # The anonymous subclass has a different effective Agent definition from the
        # configured researcher because SharedState adds LLM-visible coordination
        # Tools. D04 therefore requires a distinct semantic definition identity
        # instead of reusing the researcher's exact definition revision.
        #
        # This is a framework-private generated lineage. It is derived from the
        # wrapped researcher's *definition revision*, while its own version tracks the
        # semantic revision of the SharedState instrumentation itself. This keeps the
        # application's definition-version namespace independent from framework
        # instrumentation.
        instrumented_def = instrumented_definition_for(researcher_class)
        Class.new(researcher_class) do
          agent_definition(
            id: instrumented_def.fetch(:id),
            version: instrumented_def.fetch(:version)
          )
          tools(definitions)
        end
      end

      def instrumented_definition_for(researcher_class)
        parent_def = researcher_class.agent_definition
        parent_id = parent_def.fetch(:id)
        parent_version = parent_def.fetch(:version)

        {
          id: "Phronomy::Agent::SharedState::Instrumented/#{parent_id}@#{parent_version}".freeze,
          version: INSTRUMENTATION_DEFINITION_VERSION
        }.freeze
      end

      def build_prompt(
        original_input,
        store,
        cycle,
        extra_tools: [],
        per_agent_instruction: nil
      )
        guide = self.class._coordination || default_coordination_guide(extra_tools)

        prompt_parts = [guide]
        if per_agent_instruction
          prompt_parts << "\nYour specific focus for this session: #{per_agent_instruction}"
        end
        header = prompt_parts.join

        base = "#{header}\n\nTask: #{original_input}"
        return base if store.size == 0

        findings_text = store.read_all
          .map { |finding|
            "- [#{finding[:agent]} / cycle #{finding[:cycle]}] #{finding[:content]}"
          }
          .join("\n")

        "#{header}\n\nTask: #{original_input}\n\nFindings so far:\n#{findings_text}"
      end

      def default_coordination_guide(extra_tools)
        extra_line = if extra_tools.any?
          tool_names = extra_tools.map do |tool|
            tool.respond_to?(:tool_name) ? tool.tool_name : tool.name.to_s
          end.join(", ")
          "  You also have access to additional tools (#{tool_names}) — " \
            "use them to gather information before writing findings.\n"
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
