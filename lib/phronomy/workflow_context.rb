# frozen_string_literal: true

module Phronomy
  # Module for defining Workflow context data.
  #
  # In StateChart terminology this is the extended state/context, as opposed to
  # the current FSM phase.
  #
  # An application context may define +handle_fsm_event(event)+. FSMSession calls
  # it on the EventLoop thread before evaluating a declared transition. The
  # method may mutate the context and return +false+ to continue transition
  # evaluation, return a replacement WorkflowContext, or return +:consume+ to
  # discard a stale/unrelated event without firing a transition.
  module WorkflowContext
    def self.included(base)
      base.extend(ClassMethods)
      base.instance_variable_set(:@fields, {})
    end

    module ClassMethods
      def field(name, type: :replace, default: nil)
        # workflow_instance_id is framework-owned metadata; do not declare it as a field.
        if name.to_sym == :workflow_instance_id
          raise ArgumentError,
            "WorkflowContext field :workflow_instance_id is reserved for " \
            "framework-owned Workflow identity metadata. " \
            "Use a different field name for application state."
        end
        if default.is_a?(Array) || default.is_a?(Hash)
          raise ArgumentError,
            "Mutable default for field #{name.inspect} must be wrapped in a Proc " \
            "to avoid shared state across instances. " \
            "Use `default: -> { #{default.inspect} }` instead."
        end

        @fields[name] = {type: type, default: default}
        attr_reader name

        define_method(:"#{name}=") do |value|
          _assert_write_permitted!
          instance_variable_set(:"@#{name}", value)
        end
      end

      def fields
        @fields
      end
    end

    attr_reader :workflow_instance_id

    def phase
      @phase || :__end__
    end

    def halted?
      phase != :__end__
    end

    # Workflow identity is explicit domain metadata. The shared FSMSession still
    # delivers its existing Runtime-internal graph identity as `thread_id:` in
    # CG-01. Map that internal bridge onto the canonical Workflow identity without
    # exposing a WorkflowContext#thread_id accessor or legacy Workflow API alias.
    def set_graph_metadata(
      workflow_instance_id: nil,
      phase: nil,
      **runtime_metadata
    )
      effective_workflow_instance_id =
        workflow_instance_id || runtime_metadata[:thread_id]
      unless effective_workflow_instance_id.nil?
        @workflow_instance_id = effective_workflow_instance_id
      end
      @phase = phase unless phase.nil?
      self
    end

    def initialize(**attrs)
      unknown = attrs.keys - self.class.fields.keys
      unless unknown.empty?
        raise ArgumentError,
          "Unknown WorkflowContext field(s): #{unknown.inspect}"
      end

      self.class.fields.each do |name, config|
        default =
          if config[:default].is_a?(Proc)
            config[:default].call
          else
            config[:default]
          end
        instance_variable_set(
          :"@#{name}",
          attrs.fetch(name, default)
        )
      end
      @workflow_instance_id = nil
      @phase = :__end__
    end

    # Returns a new context with field update policies applied.
    def merge(updates)
      unknown = updates.keys - self.class.fields.keys
      unless unknown.empty?
        raise ArgumentError,
          "Unknown WorkflowContext field(s): #{unknown.inspect}"
      end

      new_attrs = {}
      self.class.fields.each_key do |name|
        field_config = self.class.fields[name]
        new_attrs[name] =
          if updates.key?(name)
            case field_config[:type]
            when :append
              Array(public_send(name)) + Array(updates[name])
            when :merge
              (public_send(name) || {}).merge(updates[name])
            else
              updates[name]
            end
          else
            deep_dup_value(public_send(name))
          end
      end

      new_context = self.class.new(**new_attrs)
      new_context.set_graph_metadata(
        workflow_instance_id: @workflow_instance_id,
        phase: @phase
      )
      new_context
    end

    def to_h
      self.class.fields.keys.each_with_object({}) do |name, result|
        result[name] = public_send(name)
      end
    end

    private

    # Workflow field mutation is permitted only on the Runtime-owned EventLoop
    # dispatch thread. All Workflow execution APIs now use that same path; there
    # is no caller-thread synchronous exception.
    def _assert_write_permitted!
      return if Phronomy::Runtime.in_event_loop_context?

      raise Phronomy::WorkflowContextOwnershipError,
        "WorkflowContext fields may only be mutated from the EventLoop dispatch " \
        "thread. Use context.merge(...) to produce a new context, or deliver " \
        "updates as event payloads."
    end

    def deep_dup_value(value)
      case value
      when Array
        value.map { |item| deep_dup_value(item) }
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = deep_dup_value(item)
        end
      when NilClass, Symbol, Integer, Float, TrueClass, FalseClass
        value
      else
        return value if value.frozen?

        begin
          value.dup
        rescue TypeError
          value
        end
      end
    end
  end
end
