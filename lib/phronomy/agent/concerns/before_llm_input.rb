# frozen_string_literal: true

module Phronomy
  module Agent
    module Concerns
      # Adds before_llm_input hook support to an agent.
      # Hooks run before EVERY LLM call (global → class → instance order) and
      # return an LLMInputPatch applied by ContextAssembler before Manifest creation.
      module BeforeLLMInput
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          def before_llm_input(callable = nil, &block)
            if callable.nil? && !block_given?
              @before_llm_input
            else
              @before_llm_input = callable || block
            end
          end

          def _before_llm_input = @before_llm_input
        end

        # Instance-level hook; takes precedence over the class-level hook.
        attr_accessor :before_llm_input

        private

        # Runs all registered hooks (global → class → instance) and merges results.
        # Later hooks override model_config_patch keys; segment_candidates are appended.
        def run_before_llm_input_hooks(call_sequence:, config:)
          hooks = [
            Phronomy.configuration.before_llm_input,
            self.class._before_llm_input,
            @before_llm_input
          ].compact

          return LLMInputPatch.empty if hooks.empty?

          ctx = LLMInputBuildContext.new(agent: self, config: config, call_sequence: call_sequence)

          merged_model_config = {}
          merged_segments = []
          merged_schema = nil
          merged_policy = nil

          hooks.each do |hook|
            result = hook.call(ctx)
            check_cancellation!(config, "invocation cancelled during before_llm_input hook")
            next unless result.is_a?(LLMInputPatch)
            merged_model_config.merge!(result.model_config_patch) if result.model_config_patch
            merged_segments.concat(Array(result.segment_candidates))
            merged_schema = result.response_schema_candidate if result.response_schema_candidate
            merged_policy = result.selection_policy_override if result.selection_policy_override
          end

          LLMInputPatch.new(
            model_config_patch: merged_model_config.empty? ? nil : merged_model_config,
            segment_candidates: merged_segments.empty? ? nil : merged_segments,
            response_schema_candidate: merged_schema,
            selection_policy_override: merged_policy
          )
        end
      end
    end
  end
end
