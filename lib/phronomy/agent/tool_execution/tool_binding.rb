# frozen_string_literal: true

module Phronomy
  module Agent
    # Builds invocation-independent Tool decorators from explicit Agent settings.
    # Authorization, execution and Orchestrator context remain with their owners.
    # @api private
    class ToolBinding
      def initialize(tool_class, alias_name:)
        @tool_class = if alias_name
          Class.new(tool_class) do
            tool_name alias_name
          end
        else
          tool_class
        end
      end

      def prepare(result_filters:)
        return @tool_class if result_filters.empty?

        Phronomy::Tool::Operation.with_result_transform(@tool_class) do |result, name, args|
          result_filters.inject(result) { |value, filter|
            filter.call(value, tool_name: name, args: args)
          }
        end
      end
    end
  end
end
