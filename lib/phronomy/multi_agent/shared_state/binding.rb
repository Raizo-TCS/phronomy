# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class SharedState
      # Connects one application's shared data to the Tools offered to members.
      # The application owns the store's shape, operations and resource lifetime.
      # @api public
      class Binding
        # @param store [Object] opaque application data passed to coordination callbacks
        # @param tools [#call] builder accepting member: (Agent class) and cycle:
        # @api public
        def initialize(store:, tools:)
          raise ArgumentError, "sharing tools must respond to call" unless tools.respond_to?(:call)

          @store = store
          @tools = tools
          freeze
        end

        # @api public
        attr_reader :store

        # Build invocation-bound Tools using the existing Agent.tools declaration shape.
        # The builder receives the registered Agent class, not an Agent instance.
        # @return [Hash<Class, String, nil>] Tool classes mapped to aliases or nil
        # @api public
        def tool_definitions(member:, cycle:)
          definitions = @tools.call(member: member, cycle: cycle)
          unless definitions.is_a?(Hash)
            raise ArgumentError, "sharing tools must return a Hash of ToolClass => alias_or_nil"
          end

          definitions.to_h do |tool_class, alias_name|
            unless tool_class.is_a?(Class) && tool_class <= Phronomy::Tool::Base
              raise ArgumentError, "sharing tools must contain Phronomy::Tool::Base classes"
            end
            [tool_class, alias_name&.to_s&.dup&.freeze]
          end.freeze
        end
      end
    end
  end
end
