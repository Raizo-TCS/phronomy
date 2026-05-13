# frozen_string_literal: true

module Phronomy
  module Graph
    # Module for defining graph context (the data that travels through a graph).
    # Include in a class and use the field DSL to declare context fields.
    #
    # In StateChart terminology this is the "extended state" or "context" —
    # data associated with the current execution that does not affect transitions
    # directly, as opposed to the current phase (which is the machine's state).
    #
    # Field update policies:
    #   :replace (default) -- overwrites with the new value
    #   :append            -- appends to an Array
    #   :merge             -- deep-merges into a Hash
    #
    # @example
    #   class ScanContext
    #     include Phronomy::Graph::Context
    #     field :messages, type: :append, default: -> { [] }
    #     field :query,    type: :replace
    #     field :metadata, type: :merge,   default: -> { {} }
    #   end
    module Context
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

      # Internal graph metadata accessors (not user-defined fields).
      # These are preserved through merge but excluded from to_h.
      attr_reader :thread_id, :current_nodes, :halted_before

      # Returns the current execution phase of the workflow.
      # Encoding:
      #   :__end__           — graph completed (or not yet started)
      #   :awaiting_<node>   — halted before <node> (interrupt_before or add_wait_state)
      #   :<node>            — halted after a node; :<node> is the next node to execute
      # @return [Symbol]
      def phase
        return :__end__ if @current_nodes.nil? || @current_nodes.empty?

        @halted_before ? :"awaiting_#{@current_nodes.first}" : @current_nodes.first
      end

      # Returns true if the graph is paused mid-execution (not yet completed).
      # @return [Boolean]
      def halted?
        @current_nodes&.any? || false
      end

      # Sets internal graph metadata. Returns self.
      # Pass +phase:+ to set the phase directly (derives current_nodes and halted_before).
      # Pass +current_nodes:+ / +halted_before:+ for the legacy explicit-field form.
      # @param thread_id [String, nil]
      # @param current_nodes [Array<Symbol>, nil]
      # @param halted_before [Boolean, nil]
      # @param phase [Symbol, nil] when given, derives current_nodes and halted_before automatically
      def set_graph_metadata(thread_id: nil, current_nodes: nil, halted_before: nil, phase: nil)
        @thread_id = thread_id
        if !phase.nil?
          if phase == :__end__
            @current_nodes = []
            @halted_before = false
          elsif phase.to_s.start_with?("awaiting_")
            @current_nodes = [phase.to_s.delete_prefix("awaiting_").to_sym]
            @halted_before = true
          else
            @current_nodes = [phase]
            @halted_before = false
          end
        else
          @current_nodes = current_nodes || []
          @halted_before = halted_before || false
        end
        self
      end

      def initialize(**attrs)
        self.class.fields.each do |name, config|
          default = config[:default].is_a?(Proc) ? config[:default].call : config[:default]
          send(:"#{name}=", attrs.fetch(name, default))
        end
        @thread_id = nil
        @current_nodes = []
        @halted_before = false
      end

      # Immutably updates context fields. Returns a new instance with the applied changes.
      # Internal graph metadata (thread_id, current_nodes, halted_before) is preserved.
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
          current_nodes: @current_nodes,
          halted_before: @halted_before
        )
        new_context
      end

      # Converts user-defined fields to a Hash (excludes internal graph metadata).
      # @return [Hash]
      def to_h
        self.class.fields.keys.each_with_object({}) do |name, h|
          h[name] = send(name)
        end
      end
    end
  end
end
