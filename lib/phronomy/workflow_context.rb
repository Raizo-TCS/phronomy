# frozen_string_literal: true

module Phronomy
  # Module for defining workflow context (the data that travels through a workflow).
  # Include in a class and use the field DSL to declare context fields.
  #
  # In StateChart terminology this is the "extended state" or "context" —
  # data associated with the current execution that does not affect transitions
  # directly, as opposed to the current phase (which is the machine's state).
  #
  # Field update policies:
  #   :replace (default) -- overwrites with the new value
  #   :append            -- appends to an Array
  #   :merge             -- shallow-merges into a Hash (top-level keys are merged; nested objects are replaced)
  #
  # @example
  #   class ScanContext
  #     include Phronomy::WorkflowContext
  #     field :messages, type: :append, default: -> { [] }
  #     field :query,    type: :replace
  #     field :metadata, type: :merge,   default: -> { {} }
  #   end
  module WorkflowContext
    def self.included(base)
      base.extend(ClassMethods)
      base.instance_variable_set(:@fields, {})
    end

    module ClassMethods
      # Defines a context field.
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

    # Internal workflow metadata accessors (not user-defined fields).
    # These are preserved through merge but excluded from to_h.
    attr_reader :thread_id

    # Returns the current execution phase of the workflow.
    # Encoding:
    #   :__end__           — workflow completed (or not yet started)
    #   :awaiting_<name>   — halted at a wait_state(:awaiting_<name>) declaration
    #   :<state>           — resuming at <state> (workflow paused before its execution)
    # @return [Symbol]
    def phase
      @phase || :__end__
    end

    # Returns true if the workflow is paused mid-execution (not yet completed).
    # @return [Boolean]
    def halted?
      phase != :__end__
    end

    # Sets internal workflow metadata. Returns self.
    # @param thread_id [String, nil]
    # @param phase [Symbol, nil]
    def set_graph_metadata(thread_id: nil, phase: nil)
      @thread_id = thread_id unless thread_id.nil?
      @phase = phase unless phase.nil?
      self
    end

    def initialize(**attrs)
      self.class.fields.each do |name, config|
        default = config[:default].is_a?(Proc) ? config[:default].call : config[:default]
        send(:"#{name}=", attrs.fetch(name, default))
      end
      @thread_id = nil
      @phase = :__end__
    end

    # Immutably updates context fields. Returns a new instance with the applied changes.
    # Internal workflow metadata (thread_id, phase) is preserved.
    # @param updates [Hash] { field_name => new_value }
    # @return [self.class] new context instance
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
      new_context = self.class.new(**new_attrs)
      new_context.set_graph_metadata(
        thread_id: @thread_id,
        phase: @phase
      )
      new_context
    end

    # Converts user-defined fields to a Hash (excludes internal workflow metadata).
    # @return [Hash]
    def to_h
      self.class.fields.keys.each_with_object({}) do |name, h|
        h[name] = send(name)
      end
    end
  end
end
