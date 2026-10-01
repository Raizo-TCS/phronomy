# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextPreparation
      SEGMENT_ORIGIN_METADATA_KEY = "phronomy_origin"
      POLICY_ORIGIN_METADATA_KEY = "context_policy_origin"
      POLICY_ITEM_ID_METADATA_KEY = "context_policy_item_id"
      BEFORE_LLM_INPUT_ORIGIN = "before_llm_input"
      HANDOFF_CONTEXT_ORIGIN = "handoff_context"

      def initialize(
        agent:,
        persistence:,
        candidate_resolver: nil,
        journal_records: nil
      )
        @agent = agent
        @persistence = persistence
        @policy = agent.class.context_policy
        @journal_records = journal_records
        @candidate_resolver = candidate_resolver || ContextCandidateResolver.new(
          content_loader: method(:fetch_content)
        )
        @input_builder = Phronomy::Context::ContextPolicyInputBuilder.new(
          content_loader: method(:fetch_content)
        )
      end

      # Builds one immutable Policy input snapshot and executes Application Policy.
      # This method must run outside a Phronomy Persistence transaction.
      def prepare_initial(input:, agent_root:, execution:, config: {}, patch: Phronomy::Context::LLMInputPatch.empty)
        projection = journal_projection(agent_root)
        model_cfg = effective_model_config(config, patch)
        tool_set = @agent.send(:tool_definition_set, additional_tools: handoff_tool_classes(config))
        system_text = build_system_text(input)
        hook_candidates = normalize_candidates(patch.segment_candidates)
        input_ref = execution.metadata.fetch("current_input_ref")
        current_input_content = @persistence.contents.fetch_text(input_ref)
        excluded = [execution.metadata["current_input_record_id"]].compact
        handoff_context = config[:phronomy_transfer_context]

        instructions = initial_instruction_items(
          system_text,
          handoff_context,
          execution: execution
        )

        candidates = resolve_record_candidates(
          projection,
          agent_root: agent_root,
          execution: execution,
          excluded_record_ids: excluded
        )
        candidates = merge_context_candidates(
          candidates,
          hook_candidates,
          handoff_context,
          agent_root: agent_root,
          execution: execution,
          call_sequence: 1
        )
        current_input = current_input_item(
          current_input_content,
          input_ref: input_ref,
          candidates: candidates,
          agent_root: agent_root,
          execution: execution
        )

        prepare(
          agent_root: agent_root,
          execution: execution,
          call_sequence: 1,
          call_mode: :ask,
          previous_manifest: nil,
          model_config: model_cfg,
          candidates: candidates,
          instruction: instructions,
          tools: tool_items(tool_set),
          current_input: current_input
        )
      end

      # Builds one immutable follow-up Policy input snapshot and executes Policy.
      # The previous finalized Manifest is read-only input; Policy-generated items
      # from a prior call are not promoted into future candidates automatically.
      def prepare_followup(
        base_manifest:,
        agent_root:,
        execution:,
        config: {},
        patch: Phronomy::Context::LLMInputPatch.empty
      )
        projection = journal_projection(agent_root)
        model_cfg = effective_model_config(config, patch)
        hook_candidates = normalize_candidates(patch.segment_candidates)
        handoff_context = config[:phronomy_transfer_context]
        tool_set = @agent.send(:tool_definition_set, additional_tools: handoff_tool_classes(config))

        instructions = retained_instruction_items(base_manifest)

        candidates = resolve_record_candidates(
          projection,
          agent_root: agent_root,
          execution: execution,
          excluded_record_ids: []
        )
        call_sequence = execution.llm_calls.length + 1
        candidates = merge_context_candidates(
          candidates,
          hook_candidates,
          handoff_context,
          agent_root: agent_root,
          execution: execution,
          call_sequence: call_sequence
        )

        prepare(
          agent_root: agent_root,
          execution: execution,
          call_sequence: call_sequence,
          call_mode: :complete,
          previous_manifest: base_manifest,
          model_config: model_cfg,
          candidates: candidates,
          instruction: instructions,
          tools: tool_items(tool_set),
          current_input: nil
        )
      end

      # Validates and canonicalizes a previously prepared Policy decision.
      # This method contains no Phronomy::Context::ContextPolicy invocation and is safe to execute in
      # the short commit transaction after the caller revalidates durable revision.

      def initial_instruction_items(system_text, handoff_context, execution:)
        instructions = []
        unless system_text.to_s.empty?
          instructions << agent_instruction_item(system_text, execution: execution)
        end
        if handoff_context
          instructions << handoff_instruction_item(handoff_context, execution: execution)
        end
        instructions
      end

      def agent_instruction_item(system_text, execution:)
        Phronomy::Context::ContextPolicyInput::InstructionItem.new(
          id: "instruction:agent:#{execution.execution_id}:1",
          kind: :instruction,
          role: :system,
          content: system_text.to_s,
          content_format: :text,
          estimated_tokens: estimate_value(system_text.to_s),
          required: true,
          provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :agent_configuration),
          metadata: {}
        )
      end

      def handoff_instruction_item(handoff_context, execution:)
        Phronomy::Context::ContextPolicyInput::InstructionItem.new(
          id: "instruction:handoff:#{execution.execution_id}:1",
          kind: :handoff_responsibility,
          role: :user,
          content: handoff_context.responsibility.to_s,
          content_format: :text,
          estimated_tokens: estimate_value(handoff_context.responsibility.to_s),
          required: true,
          provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :handoff_context),
          metadata: {SEGMENT_ORIGIN_METADATA_KEY => HANDOFF_CONTEXT_ORIGIN}
        )
      end

      def retained_instruction_items(base_manifest)
        base_manifest.segments.filter_map do |segment|
          next unless retained_base_instruction?(segment)
          instruction_item_from_manifest(segment)
        end
      end

      def resolve_record_candidates(projection, agent_root:, execution:, excluded_record_ids:)
        generation = agent_root.transcript_generation
        eligible_working = Array(execution.working_records).select do |record|
          record.context_candidate && record.context_generation == generation
        end
        @candidate_resolver.resolve(
          prior_records: projection.context_records,
          working_records: eligible_working,
          excluded_record_ids: excluded_record_ids
        )
      end

      def merge_context_candidates(
        candidates, hook_candidates, handoff_context,
        agent_root:, execution:, call_sequence:
      )
        candidates = merge_hook_candidates(
          candidates,
          hook_candidates,
          agent_root: agent_root,
          execution: execution,
          call_sequence: call_sequence
        )
        merge_handoff_candidates(
          candidates,
          handoff_context,
          execution: execution
        )
      end

      def current_input_item(content, input_ref:, candidates:, agent_root:, execution:)
        next_sequence = Array(candidates).filter_map(&:sequence).max.to_i + 1
        Phronomy::Context::ContextPolicyInput::ConversationItem.new(
          id: "current-input:#{execution.execution_id}",
          kind: :current_input,
          role: :user,
          content: content,
          content_format: :text,
          sequence: next_sequence,
          estimated_tokens: estimate_value(content),
          required: true,
          provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(
            origin: :working,
            content_ref: input_ref,
            record_id: execution.metadata["current_input_record_id"],
            agent_id: agent_root.agent_id,
            execution_id: execution.execution_id
          ),
          tool_call_id: nil,
          tool_call_ids: [],
          delivery: :ask_argument,
          metadata: {
            "source_agent_id" => agent_root.agent_id,
            "source_execution_id" => execution.execution_id,
            "handoff_policy_category" => "current_request"
          }
        )
      end

      def prepare(
        agent_root:,
        execution:,
        call_sequence:,
        call_mode:,
        previous_manifest:,
        model_config:,
        candidates:,
        instruction:,
        tools:,
        current_input:
      )
        token_budget = Phronomy.configuration.llm_adapter.input_budget(model_config)
        policy_input = @input_builder.build(
          agent_id: agent_root.agent_id,
          execution_id: execution.execution_id,
          call_sequence: call_sequence,
          call_mode: call_mode,
          candidates: candidates,
          instruction: instruction,
          tools: tools,
          current_input: current_input,
          token_budget: token_budget,
          model_config: model_config,
          previous_manifest: previous_manifest,
          metadata: {
            "agent_revision" => agent_root.agent_revision,
            "context_revision" => agent_root.context_revision,
            "journal_position" => agent_root.journal_position,
            "execution_revision" => execution.execution_revision
          }
        )
        Phronomy::Context::Assembly.new.prepare(
          input: policy_input, policy: @policy,
          adapter_identity: Phronomy.configuration.llm_adapter.identity
        )
      end

      def journal_projection(agent_root)
        if @journal_records
          JournalProjection.new(agent_root: agent_root, records: @journal_records)
        else
          JournalProjection.new(persistence: @persistence, agent_root: agent_root)
        end
      end

      def retained_base_instruction?(segment)
        origin = segment.metadata[POLICY_ORIGIN_METADATA_KEY]
        return %w[agent_configuration handoff_context].include?(origin) if origin

        # Current-format manifests created before ACS-04 do not have the origin
        # marker. Preserve only the legacy base instruction shapes.
        (segment.role == :system &&
          segment.metadata[SEGMENT_ORIGIN_METADATA_KEY] != BEFORE_LLM_INPUT_ORIGIN) ||
          segment.category.to_sym == :handoff_responsibility
      end

      def instruction_item_from_manifest(segment)
        origin = segment.metadata[POLICY_ORIGIN_METADATA_KEY] ||
          ((segment.category.to_sym == :handoff_responsibility) ? "handoff_context" : "agent_configuration")
        Phronomy::Context::ContextPolicyInput::InstructionItem.new(
          id: segment.metadata[POLICY_ITEM_ID_METADATA_KEY] || "manifest-instruction:#{segment.position}",
          kind: segment.category,
          role: segment.role,
          content: fetch_content(segment.content_ref),
          content_format: :text,
          estimated_tokens: estimate_value(fetch_content(segment.content_ref)),
          required: true,
          provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(
            origin: origin.to_sym,
            content_ref: segment.content_ref
          ),
          metadata: segment.metadata
        )
      end

      def tool_items(tool_set)
        tool_set.definitions.map do |definition|
          name = definition.fetch("name")
          Phronomy::Context::ContextPolicyInput::ToolItem.new(
            id: "tool:#{name}",
            definition: definition,
            estimated_tokens: estimate_value(definition),
            required: false,
            provenance: Phronomy::Context::ContextPolicyInput::Provenance.new(origin: :agent_configuration),
            metadata: {}
          )
        end.freeze
      end

      def effective_model_config(config, patch)
        apply_model_config_patch(model_config(config), patch.model_config_patch)
      end

      def model_config(config)
        {
          "model" => @agent.class.model&.to_s,
          "provider" => @agent.class.provider&.to_s,
          "temperature" => @agent.class.temperature,
          "max_output_tokens" => @agent.class.max_output_tokens,
          "cache_instructions" => !!@agent.class.cache_instructions
        }.compact
      end

      def apply_model_config_patch(base, patch)
        return base unless patch
        values = patch.to_h.transform_keys(&:to_s)
        if values.key?("context_window")
          raise Phronomy::ConfigurationError,
            "context_window is model metadata; configure the RubyLLM model registry"
        end
        if values.key?("max_output_tokens") && !values["max_output_tokens"].nil?
          cap = Integer(values["max_output_tokens"])
          raise ArgumentError, "max_output_tokens must be positive" unless cap.positive?
          values["max_output_tokens"] = cap
        end
        base.merge(values).compact
      end

      def normalize_candidates(candidates)
        Array(candidates).map do |candidate|
          hash = candidate.to_h
          content = hash.fetch(:content) { hash.fetch("content") }
          category = (hash[:category] || hash["category"] || :knowledge).to_sym
          role = (hash[:role] || hash["role"] || default_role(category)).to_sym
          metadata = (hash[:metadata] || hash["metadata"] || {})
            .to_h
            .transform_keys(&:to_s)
          validate_application_metadata!(metadata, source: "Phronomy::Context::LLMInputPatch segment candidate")
          {
            content: content,
            category: category,
            role: role,
            metadata: metadata
          }
        end
      end

      def validate_application_metadata!(metadata, source:)
        conflicts = metadata.keys.map(&:to_s) & Phronomy::Context::ContextPolicyInput::FRAMEWORK_METADATA_KEYS
        return if conflicts.empty?

        raise ArgumentError,
          "#{source} metadata uses Framework-reserved key(s): #{conflicts.sort.inspect}"
      end

      def merge_hook_candidates(candidates, hooks, agent_root:, execution:, call_sequence:)
        next_sequence = Array(candidates).filter_map(&:sequence).max.to_i
        generated = hooks.each_with_index.map do |hook, index|
          content = hook.fetch(:content)
          content_ref = if content.is_a?(String)
            @persistence.contents.put_text(content)
          else
            @persistence.contents.put_json(content)
          end
          metadata = hook.fetch(:metadata).merge(
            SEGMENT_ORIGIN_METADATA_KEY => BEFORE_LLM_INPUT_ORIGIN,
            "estimated_tokens" => estimate_value(content),
            "source_kind" => "hook",
            "content_format" => content.is_a?(String) ? "text" : "json"
          )
          Phronomy::Context::Candidate.new(
            candidate_id: "hook:#{execution.execution_id}:#{call_sequence}:#{index}",
            source_kind: :hook,
            category: hook.fetch(:category),
            role: hook.fetch(:role),
            content_ref: content_ref,
            record_id: nil,
            agent_id: agent_root.agent_id,
            execution_id: execution.execution_id,
            llm_call_id: nil,
            tool_call_id: nil,
            sequence: next_sequence + index + 1,
            constraint: Phronomy::Context::Constraint.selectable(origin: :context_policy),
            priority: 0,
            metadata: metadata
          )
        end
        (Array(candidates) + generated)
          .sort_by { |candidate| [candidate.sequence || 0, candidate.candidate_id] }
          .freeze
      end

      def merge_handoff_candidates(candidates, handoff_context, execution:)
        return Array(candidates).freeze unless handoff_context

        unless handoff_context.is_a?(Phronomy::Agent::TransferContext)
          raise ArgumentError, "phronomy_transfer_context must be a TransferContext"
        end

        next_sequence = Array(candidates).filter_map(&:sequence).max.to_i
        transferred = handoff_context.items.each_with_index.map do |item, index|
          content_ref = if item.content_format == :json
            @persistence.contents.put_json(item.content)
          else
            @persistence.contents.put_text(item.content.to_s)
          end
          metadata = item.metadata.merge(
            SEGMENT_ORIGIN_METADATA_KEY => HANDOFF_CONTEXT_ORIGIN,
            "estimated_tokens" => estimate_value(item.content),
            "source_kind" => "handoff",
            "content_format" => item.content_format.to_s,
            "handoff_policy_category" => item.policy_category.to_s,
            "handoff_provenance" => item.provenance.to_h
          )

          Phronomy::Context::Candidate.new(
            candidate_id: "handoff:#{execution.execution_id}:#{index}:#{item.provenance.origin_record_id || item.provenance.origin_tool_call_id || index}",
            source_kind: :handoff,
            category: item.candidate_category,
            role: item.role,
            content_ref: content_ref,
            record_id: nil,
            agent_id: item.provenance.origin_agent_id,
            execution_id: execution.execution_id,
            llm_call_id: item.provenance.origin_llm_call_id,
            tool_call_id: item.tool_call_id,
            sequence: next_sequence + index + 1,
            constraint: Phronomy::Context::Constraint.selectable(origin: :handoff_context),
            priority: 50,
            metadata: metadata
          )
        end

        (Array(candidates) + transferred)
          .sort_by { |candidate| [candidate.sequence || 0, candidate.candidate_id] }
          .freeze
      end

      def default_role(category)
        (category == :instruction) ? :system : :user
      end

      def handoff_tool_classes(config)
        Array(config[:phronomy_control_bindings]).map(&:tool_class).freeze
      end

      def estimate_value(value)
        bytes = value.is_a?(String) ? value : Phronomy::CanonicalJSON.dump(value)
        Phronomy::LlmContextWindow::TokenEstimator.estimate(bytes)
      end

      def fetch_content(ref)
        @persistence.contents.fetch_text(ref)
      rescue
        @persistence.contents.fetch(ref)
      end

      def build_system_text(input)
        @agent.send(:build_instructions, input)
      end
    end
  end
end
