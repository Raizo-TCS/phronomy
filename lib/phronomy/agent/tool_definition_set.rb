# frozen_string_literal: true

module Phronomy
  module Agent
    class ToolDefinitionSet
      attr_reader :runtime_tools, :definitions

      def self.build(agent, additional_tools: [])
        runtime_tools = (agent.class.tools + Array(additional_tools)).freeze
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
        @runtime_tools = Array(runtime_tools).freeze
        @definitions = Immutable.copy(definitions)
        validate_unique_names!
        freeze
      end

      def select_definitions(expected_definitions)
        expected = Immutable.copy(Array(expected_definitions))
        current_by_name = definitions.each_with_index.to_h do |definition, index|
          [definition.fetch("name"), [definition, runtime_tools.fetch(index)]]
        end
        seen = {}
        selected_tools = []
        selected_definitions = []

        expected.each do |definition|
          name = definition.fetch("name").to_s
          raise ArgumentError, "duplicate selected Tool definition: #{name}" if seen[name]
          seen[name] = true

          current_definition, runtime_tool = current_by_name.fetch(name) do
            raise Phronomy::ConfigurationError,
              "ContextPolicy selected Tool not present in current Agent configuration: #{name}"
          end
          unless Phronomy::CanonicalJSON.dump(current_definition) ==
              Phronomy::CanonicalJSON.dump(definition)
            raise Phronomy::ConfigurationError,
              "Agent Tool definition changed after ContextPolicy selection: #{name}"
          end

          selected_tools << runtime_tool
          selected_definitions << current_definition
        end

        self.class.new(
          runtime_tools: selected_tools,
          definitions: selected_definitions
        )
      end

      private

      def validate_unique_names!
        names = definitions.map { |definition| definition.fetch("name").to_s }
        duplicates = names.group_by(&:itself).select { |_name, values| values.length > 1 }.keys
        return if duplicates.empty?

        raise Phronomy::ConfigurationError,
          "duplicate effective Tool definition name(s): #{duplicates.inspect}"
      end
    end
  end
end
