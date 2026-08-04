# frozen_string_literal: true

module Phronomy
  module Agent
    class ToolDefinitionSet
      attr_reader :runtime_tools, :definitions

      def self.build(agent)
        runtime_tools = (agent.class.tools + agent.send(:_handoff_tools)).freeze
        definitions = runtime_tools.map do |tool_class|
          prepared = agent.send(:prepare_tool_class, tool_class)
          tool = prepared.is_a?(Class) ? prepared.new : prepared
          {
            "name" => tool.name.to_s,
            "description" => tool.description.to_s,
            "parameters_schema" => normalize(
              tool.respond_to?(:parameters_schema) ? tool.parameters_schema : {}
            ),
            "provider_options" => normalize(
              tool.respond_to?(:provider_options) ? tool.provider_options : {}
            )
          }
        end.freeze
        new(runtime_tools: runtime_tools, definitions: definitions)
      end

      def self.normalize(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, normalize(child)] }
        when Array
          value.map { |child| normalize(child) }
        when Symbol
          value.to_s
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          if value.respond_to?(:to_json_schema)
            normalize(value.to_json_schema)
          elsif value.respond_to?(:to_h)
            normalize(value.to_h)
          else
            raise ArgumentError, "unsupported tool definition value: #{value.class}"
          end
        end
      end

      def initialize(runtime_tools:, definitions:)
        @runtime_tools = runtime_tools
        @definitions = Immutable.copy(definitions)
        freeze
      end
    end
  end
end
