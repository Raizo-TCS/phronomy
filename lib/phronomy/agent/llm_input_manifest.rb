# frozen_string_literal: true

module Phronomy
  module Agent
    class LLMInputManifest
      VERSION = 1
      CALL_MODES = %i[ask complete].freeze

      Segment = Data.define(
        :position, :category, :role, :content_ref, :delivery,
        :tool_call_id, :metadata
      ) do
        def initialize(**values)
          super(**values.merge(metadata: Immutable.copy(values[:metadata] || {})))
          freeze
        end

        def to_h
          {
            "position" => position,
            "category" => category.to_s,
            "role" => role&.to_s,
            "content_ref" => content_ref,
            "delivery" => delivery.to_s,
            "tool_call_id" => tool_call_id,
            "metadata" => metadata
          }.compact
        end
      end

      attr_reader :version, :call_sequence, :call_mode,
        :assembly_policy_version, :segments,
        :model_config_ref, :tool_definitions_ref, :response_schema_ref,
        :ruby_llm_version, :adapter_name, :adapter_version

      def initialize(
        call_sequence:,
        call_mode:,
        segments:,
        model_config_ref:,
        tool_definitions_ref: nil,
        response_schema_ref: nil,
        assembly_policy_version: 1,
        ruby_llm_version: nil,
        adapter_name: nil,
        adapter_version: nil,
        version: VERSION
      )
        @version = Integer(version)
        @call_sequence = Integer(call_sequence)
        @call_mode = call_mode.to_sym
        @assembly_policy_version = Integer(assembly_policy_version)
        @segments = Array(segments).sort_by(&:position).freeze
        @model_config_ref = model_config_ref.to_s.freeze
        @tool_definitions_ref = tool_definitions_ref&.to_s&.freeze
        @response_schema_ref = response_schema_ref&.to_s&.freeze
        @ruby_llm_version = ruby_llm_version&.to_s&.freeze
        @adapter_name = adapter_name&.to_s&.freeze
        @adapter_version = adapter_version&.to_s&.freeze
        validate!
        freeze
      end

      def referenced_content_refs
        ([model_config_ref, tool_definitions_ref, response_schema_ref] +
          segments.map(&:content_ref)).compact.uniq.freeze
      end

      def to_h
        {
          "version" => version,
          "call_sequence" => call_sequence,
          "call_mode" => call_mode.to_s,
          "assembly_policy_version" => assembly_policy_version,
          "segments" => segments.map(&:to_h),
          "model_config_ref" => model_config_ref,
          "tool_definitions_ref" => tool_definitions_ref,
          "response_schema_ref" => response_schema_ref,
          "ruby_llm_version" => ruby_llm_version,
          "adapter_name" => adapter_name,
          "adapter_version" => adapter_version
        }.compact
      end

      private

      def validate!
        raise ArgumentError, "invalid manifest call mode: #{call_mode.inspect}" unless CALL_MODES.include?(call_mode)
        raise ArgumentError, "call_sequence must be positive" unless call_sequence.positive?
        expected = (0...segments.length).to_a
        actual = segments.map(&:position)
        raise ArgumentError, "manifest positions must be contiguous: #{actual.inspect}" unless actual == expected

        ask_count = segments.count { |segment| segment.delivery == :ask_argument }
        expected_ask_count = (call_mode == :ask) ? 1 : 0
        unless ask_count == expected_ask_count
          raise ArgumentError,
            "#{call_mode} manifest requires #{expected_ask_count} ask_argument segment(s), got #{ask_count}"
        end
      end
    end
  end
end
