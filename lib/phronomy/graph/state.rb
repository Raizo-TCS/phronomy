# frozen_string_literal: true

module Phronomy
  module Graph
    # Module for defining graph state.
    # Include in a class and use the field DSL to declare state fields.
    #
    # Field update policies:
    #   :replace (default) -- overwrites with the new value
    #   :append            -- appends to an Array
    #   :merge             -- deep-merges into a Hash
    #
    # @example
    #   class MyState
    #     include Phronomy::Graph::State
    #     field :messages, type: :append, default: -> { [] }
    #     field :query,    type: :replace
    #     field :metadata, type: :merge,   default: -> { {} }
    #   end
    module State
      def self.included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@fields, {})
      end

      module ClassMethods
        # Defines a state field.
        # @param name [Symbol]
        # @param type [Symbol] :replace / :append / :merge
        # @param default [Object, Proc, nil]
        def field(name, type: :replace, default: nil)
          @fields[name] = {type: type, default: default}
          attr_accessor name
        end

        def fields
          @fields
        end
      end

      def initialize(**attrs)
        self.class.fields.each do |name, config|
          default = config[:default].is_a?(Proc) ? config[:default].call : config[:default]
          send(:"#{name}=", attrs.fetch(name, default))
        end
      end

      # Immutably updates state fields. Returns a new instance with the applied changes.
      # @param updates [Hash] { field_name => new_value }
      # @return [self.class] new state instance
      def merge(updates)
        new_attrs = {}
        self.class.fields.each_key do |name|
          field_config = self.class.fields[name]
          new_attrs[name] = if updates.key?(name)
            case field_config[:type]
            when :append
              Array(send(name)) + Array(updates[name])
            when :merge
              (send(name) || {}).merge(updates[name])
            else
              updates[name]
            end
          else
            send(name)
          end
        end
        self.class.new(**new_attrs)
      end

      # Converts all fields to a Hash.
      # @return [Hash]
      def to_h
        self.class.fields.keys.each_with_object({}) do |name, h|
          h[name] = send(name)
        end
      end
    end
  end
end
