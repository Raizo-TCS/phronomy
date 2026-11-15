# frozen_string_literal: true

require "digest"

module Phronomy
  module MultiAgent
    # Coordinates members through default findings or application-defined shared data.
    # @api public
    class SharedState
      # Semantic revision of the framework-owned SharedState instrumentation
      # applied on top of one specific researcher definition revision.
      #
      # The generated definition ID below already includes the wrapped
      # researcher's definition ID/version. Increment this value only when the
      # semantics of SharedState's injected coordination capabilities change.
      INSTRUMENTATION_DEFINITION_VERSION = 1
      private_constant :INSTRUMENTATION_DEFINITION_VERSION

      # Findings shared by the sequential members of one invocation.
      # @api public
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

        # Declare application-owned sharing for each invocation. The provider's
        # open(input:, config:) method must synchronously yield one Binding.
        # Its block scope owns any connection or other application resource.
        # Increment version when the shared Tool schemas or meanings change.
        # @param provider [#open]
        # @param id [String] stable application sharing definition identity
        # @param version [Integer] positive sharing definition revision
        # @api public
        def sharing(provider, id:, version:)
          raise ArgumentError, "sharing provider must respond to open" unless provider.respond_to?(:open)
          unless id.is_a?(String) && !id.strip.empty?
            raise ArgumentError, "sharing id must be a nonempty String"
          end
          unless version.is_a?(Integer) && version.positive?
            raise ArgumentError, "sharing version must be a positive Integer"
          end

          @sharing = {provider: provider, id: id.dup.freeze, version: version}.freeze
        end

        # @api private
        def _sharing = @sharing

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
        return invoke_with_sharing(input, config, self.class._sharing) if self.class._sharing

        store = KnowledgeStore.new
        cycles, terminated_by = coordinate_members(input, store)

        {output: aggregate_findings(store), cycles: cycles, terminated_by: terminated_by}
      end

      private

      def coordinate_members(input, store)
        max_cycles = self.class._max_cycles
        deadline = self.class._timeout ? Time.now + self.class._timeout : nil
        terminated_by = :max_cycles
        completed_cycles = 0
        cycle_limit = max_cycles || Float::INFINITY

        (1..cycle_limit).each do |cycle|
          if block_given?
            yield cycle
          else
            invoke_members(input, store, cycle)
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

        [completed_cycles, terminated_by]
      end

      def invoke_members(input, store, cycle)
        self.class._members.each do |member_config|
          invoke_researcher(
            member_config[:klass], store, cycle, input, member_config[:instruction]
          )
        end
      end

      def aggregate_findings(store)
        if self.class._aggregator
          self.class._aggregator.call(store)
        else
          store.read_all
        end
      end

      def validate_termination!
        return if self.class._max_cycles || self.class._timeout

        raise ArgumentError,
          "max_cycles or timeout must be configured before invoking SharedState"
      end

      def invoke_with_sharing(input, config, sharing)
        unless self.class._aggregator
          raise ArgumentError, "aggregate must be configured when sharing is configured"
        end

        open_sharing(sharing, input, config) do |binding|
          cycles, terminated_by = coordinate_members(input, binding.store) do |cycle|
            invoke_shared_members(input, binding, cycle, sharing)
          end
          {output: aggregate_findings(binding.store), cycles: cycles, terminated_by: terminated_by}
        end
      end

      def open_sharing(sharing, input, config)
        opening_thread = Thread.current
        active = true
        entered = completed = false
        result = callback_error = nil

        sharing.fetch(:provider).open(input: input, config: config) do |binding|
          unless active && Thread.current.equal?(opening_thread)
            raise ArgumentError, "sharing provider must yield synchronously within open"
          end
          raise ArgumentError, "sharing provider must yield exactly once" if entered

          entered = true
          unless binding.is_a?(Binding)
            raise ArgumentError, "sharing provider must yield a SharedState::Binding"
          end

          result = yield binding
          completed = true
        rescue => error
          callback_error = error
          raise
        end

        raise callback_error if callback_error
        unless entered && completed
          raise ArgumentError, "sharing provider must yield exactly once and complete the block"
        end

        result
      ensure
        active = false
      end

      def invoke_shared_members(input, binding, cycle, sharing)
        self.class._members.each do |member_config|
          member = member_config.fetch(:klass)
          definitions = shared_tool_definitions(member, binding, cycle)
          instrumented = build_shared_researcher(member, definitions, sharing)
          prompt = shared_prompt(input, member_config[:instruction])
          invoke_shared_researcher(instrumented, prompt)
        end
      end

      def invoke_shared_researcher(instrumented, prompt)
        agent = instrumented.new
        suspended = false
        result = agent.invoke(prompt)
        if result.is_a?(Hash) && result[:suspended]
          suspended = true
          raise MemberLifecycleError.new(agent: agent, result: result, reason: :suspended)
        end
        result
      ensure
        release_shared_member(agent, result, $!) if agent && !suspended
      end

      def release_shared_member(agent, result, primary_error)
        agent.unload!
      rescue => release_error
        error = MemberLifecycleError.new(agent: agent, result: result, reason: :release_failed,
          primary_error: primary_error, release_error: release_error)
        raise error, cause: primary_error || release_error
      end

      def shared_tool_definitions(member, binding, cycle)
        definitions = member.tools.to_h { |tool| [tool, member.tool_aliases[tool]] }
        added = binding.tool_definitions(member: member, cycle: cycle)
        unless (definitions.keys & added.keys).empty?
          raise ArgumentError, "sharing Tool classes must not replace member Tools"
        end

        definitions = definitions.merge(added)
        names = definitions.map { |tool, alias_name| (alias_name || tool.tool_name).to_s }
        if names.any?(&:empty?) || names.uniq.length != names.length
          raise ArgumentError, "sharing and member Tools must have distinct nonempty names or aliases"
        end
        definitions
      end

      def build_shared_researcher(member, definitions, sharing)
        definition = shared_definition_for(member, sharing)
        member.with_tools(definitions, id: definition.fetch(:id), version: definition.fetch(:version))
      end

      def shared_definition_for(member, sharing)
        parent = member.agent_definition
        identity = [parent.fetch(:id), parent.fetch(:version), sharing.fetch(:id), sharing.fetch(:version)]
        digest = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(identity))
        {id: "Phronomy::MultiAgent::SharedState::Application/#{digest}", version: 1}
      end

      def shared_prompt(input, instruction)
        guide = self.class._coordination ||
          "Use the provided Tools to collaborate through the application's shared data."
        parts = [guide]
        parts << "\nYour specific focus for this session: #{instruction}" if instruction
        parts << "\n\nTask: #{input}"
        parts.join
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
        read_tool = build_read_tool(store)
        write_tool = build_write_tool(store, cycle, agent_key)

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
        researcher_class.with_tools(
          definitions,
          id: instrumented_def.fetch(:id),
          version: instrumented_def.fetch(:version)
        )
      end

      def build_read_tool(store)
        Class.new(Phronomy::Tool::Base) do
          tool_name "read_store"
          description "Read all current findings from the shared knowledge store. " \
            "Call this to see what other researchers have discovered."
          execution_mode :cooperative

          define_method(:execute) { store.read_all.to_json }
        end
      end

      def build_write_tool(store, cycle, agent_key)
        Class.new(Phronomy::Tool::Base) do
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
      end

      def instrumented_definition_for(researcher_class)
        parent_def = researcher_class.agent_definition
        parent_id = parent_def.fetch(:id)
        parent_version = parent_def.fetch(:version)

        {
          # Keep the existing semantic ID across the Ruby namespace migration.
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
