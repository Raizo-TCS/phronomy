# frozen_string_literal: true

module Phronomy
  module Agent
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

      attr_accessor :before_llm_input

      private

      def run_before_llm_input_hooks(call_sequence:, config:)
        hooks = [
          Phronomy.configuration.before_llm_input,
          self.class._before_llm_input,
          @before_llm_input
        ].compact
        return Phronomy::Context::LLMInputPatch.empty if hooks.empty?

        definition = self.class.agent_definition
        context = Phronomy::Context::LLMInputBuildContext.new(
          agent_id: agent_id,
          agent_definition_id: definition.fetch(:id),
          agent_definition_version: definition.fetch(:version),
          config: config,
          call_sequence: call_sequence
        )
        model_patch = {}
        segments = []

        hooks.each do |hook|
          result = hook.call(context)
          check_cancellation!(config, "invocation cancelled during before_llm_input hook")
          next if result.nil?
          unless result.is_a?(Phronomy::Context::LLMInputPatch)
            raise TypeError,
              "before_llm_input must return Phronomy::Context::LLMInputPatch or nil, got #{result.class}"
          end
          model_patch.merge!(result.model_config_patch) if result.model_config_patch
          segments.concat(Array(result.segment_candidates))
        end

        Phronomy::Context::LLMInputPatch.new(
          model_config_patch: model_patch.empty? ? nil : model_patch,
          segment_candidates: segments.empty? ? nil : segments
        )
      end
    end
  end
end
