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
      attr_reader :thread_id

      # Returns the current execution phase of the workflow.
      # Encoding:
      #   :__end__           — graph completed (or not yet started)
      #   :awaiting_<node>   — halted before <node> (interrupt_before or add_wait_state)
      #   :<node>            — about to execute <node> (halted after previous node)
      # @return [Symbol]
      def phase
        @phase || :__end__
      end

      # Backward-compatibility wrapper. Returns the next node(s) to execute as an Array.
      # Derives from +#phase+; at most one element is returned.
      # @deprecated Use +#phase+ directly.
      # @return [Array<Symbol>]
      def current_nodes
        p = phase
        return [] if p == :__end__
        # :__at_finish__ — halted after the last active node; resume will complete the graph.
        return [:__end__] if p == :__at_finish__

        p.to_s.start_with?("awaiting_") ? [p.to_s.delete_prefix("awaiting_").to_sym] : [p]
      end

      # Backward-compatibility wrapper. Returns true when halted before a node.
      # @deprecated Use +phase.to_s.start_with?("awaiting_")+ directly.
      # @return [Boolean]
      def halted_before
        phase.to_s.start_with?("awaiting_")
      end

      # Returns true if the graph is paused mid-execution (not yet completed).
      # @return [Boolean]
      def halted?
        phase != :__end__
      end

      # Sets internal graph metadata. Returns self.
      # Pass +phase:+ to set the phase directly (preferred form).
      # Pass +current_nodes:+ / +halted_before:+ for backward-compatible form
      # (derives phase from the first element of current_nodes and halted_before).
      # @param thread_id [String, nil]
      # @param current_nodes [Array<Symbol>, nil]
      # @param halted_before [Boolean, nil]
      # @param phase [Symbol, nil] when given, sets @phase directly
      def set_graph_metadata(thread_id: nil, current_nodes: nil, halted_before: nil, phase: nil)
        @thread_id = thread_id unless thread_id.nil?
        if !phase.nil?
          @phase = phase
        elsif !current_nodes.nil? || !halted_before.nil?
          nodes = current_nodes || []
          hb = halted_before || false
          @phase = if nodes.empty?
            :__end__
          elsif hb
            :"awaiting_#{nodes.first}"
          elsif nodes.first == :__end__
            # Legacy deserialization: current_nodes = [:__end__], halted_before = false
            # represents the "halted at finish boundary" state (:__at_finish__).
            :__at_finish__
          else
            nodes.first
          end
        end
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
      # Internal graph metadata (thread_id, phase) is preserved.
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
