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
      # @raise [ArgumentError] if +default+ is a plain Array or Hash (use a Proc instead)
      # @api public
      def field(name, type: :replace, default: nil)
        if default.is_a?(Array) || default.is_a?(Hash)
          raise ArgumentError,
            "Mutable default for field #{name.inspect} must be wrapped in a Proc " \
            "to avoid shared state across instances. " \
            "Use `default: -> { #{default.inspect} }` instead."
        end

        @fields[name] = {type: type, default: default}

        # Define getter.
        attr_reader name

        # Define write-guarded setter.  Mutation from outside the EventLoop
        # dispatch thread raises WorkflowContextOwnershipError in EventLoop mode.
        define_method(:"#{name}=") do |value|
          _assert_write_permitted!
          instance_variable_set(:"@#{name}", value)
        end
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
    # @api public
    # mutant:disable - @phase is always non-nil (set to :__end__ in initialize, only changed by set_graph_metadata which never sets nil), so the || :__end__ fallback branch is never reached — all mutations of the right-hand side are genuine equivalents
    def phase
      @phase || :__end__
    end

    # Returns true if the workflow is paused mid-execution (not yet completed).
    # @return [Boolean]
    # @api public
    # mutant:disable - phase != :__end__ vs !phase.eql?(:__end__) vs !phase.equal?(:__end__) are genuine equivalents for Symbol (Symbols are interned so == / eql? / equal? all behave identically)
    def halted?
      phase != :__end__
    end

    # Sets internal workflow metadata. Returns self.
    # @param thread_id [String, nil]
    # @param phase [Symbol, nil]
    # @api public
    # mutant:disable - mutations replacing return value `self` with nil or removing the last line are genuine equivalents: callers chain on the return value only in merge which immediately discards it
    def set_graph_metadata(thread_id: nil, phase: nil)
      @thread_id = thread_id unless thread_id.nil?
      @phase = phase unless phase.nil?
      self
    end

    # mutant:disable - multiple genuine equivalent mutations: is_a?(Proc) vs instance_of?(Proc) (Proc has no subclasses in practice), config[]/fetch() for always-present :default key, @thread_id=nil removal (unset ivar is already nil), @phase=:__end__ → nil or removal (phase method returns :__end__ via @phase||:__end__ fallback), raise message #{.inspect} vs #{} (spec checks exception class not message text)
    def initialize(**attrs)
      unknown = attrs.keys - self.class.fields.keys
      raise ArgumentError, "Unknown WorkflowContext field(s): #{unknown.inspect}" unless unknown.empty?

      self.class.fields.each do |name, config|
        default = config[:default].is_a?(Proc) ? config[:default].call : config[:default]
        # Bypass the write guard in initialize — ownership enforcement begins
        # after construction is complete.
        instance_variable_set(:"@#{name}", attrs.fetch(name, default))
      end
      @thread_id = nil
      @phase = :__end__
    end

    # Returns a new context instance with the specified field updates applied.
    # Updated fields follow the field's declared +:type+ semantics (:replace, :append,
    # or :merge). Unchanged fields are deep-copied on a best-effort basis — objects
    # that do not support +#dup+ (e.g. integers, frozen objects) are carried over
    # by reference. Internal workflow metadata (thread_id, phase) is preserved.
    # @param updates [Hash] { field_name => new_value }
    # @return [self.class] new context instance
    # @raise [ArgumentError] if updates contains keys that are not declared fields
    # @api public
    # mutant:disable - multiple genuine equivalent mutations: send/public_send/__send__ are identical (all field accessors are public), fields[]/fetch() and field_config[]/fetch() for always-present keys, updates[]/fetch() when updates.key?(name) is already true, Array() wrapping for append fields that always hold Arrays, (send||{})/send equivalence for merge fields that always hold Hashes, deep_dup_value(send) vs send are equivalent under killfork (coverage selection does not trace the deep_dup_value call site across the fork boundary), raise message inspect vs to_s (spec checks exception class only)
    def merge(updates)
      unknown = updates.keys - self.class.fields.keys
      raise ArgumentError, "Unknown WorkflowContext field(s): #{unknown.inspect}" unless unknown.empty?

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
          deep_dup_value(send(name))
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
    # @api public
    # mutant:disable - send/public_send/__send__ are genuine equivalents (all field accessors are public methods)
    def to_h
      self.class.fields.keys.each_with_object({}) do |name, h|
        h[name] = send(name)
      end
    end

    private

    # Asserts that the calling thread is allowed to mutate this context.
    # No-op when EventLoop mode is disabled.
    # @raise [Phronomy::WorkflowContextOwnershipError] when called from a
    #   non-EventLoop thread in EventLoop mode.
    # @api private
    # mutant:disable - multiple genuine equivalent mutations: defined?(Phronomy::EventLoop)&& removal is genuine because EventLoop is always loaded in the killfork environment; true&& is genuine (truthy guard); EventLoop.current? resolves to Phronomy::EventLoop.current? within the Phronomy module; WorkflowContextOwnershipError resolves to Phronomy::WorkflowContextOwnershipError within the module; raise without message or with nil message is genuine (spec checks exception class, not message text)
    def _assert_write_permitted!
      return unless defined?(Phronomy::EventLoop) &&
        Phronomy.configuration.event_loop
      return if Phronomy::EventLoop.current?

      raise Phronomy::WorkflowContextOwnershipError,
        "WorkflowContext fields may only be mutated from the EventLoop dispatch " \
        "thread. Use context.merge(...) to produce a new context, or deliver " \
        "updates as event payloads."
    end

    # Performs a deep copy of a value for immutable context propagation.
    # Arrays and Hashes are deep-duplicated recursively.
    # Immutable values (nil, Symbol, Integer, Float, true/false, frozen String) are returned as-is.
    # Other objects are dup'd (best-effort shallow copy for custom types).
    # Objects that cannot be dup'd (e.g. Proc, Method) are returned as-is.
    # mutant:disable - multiple genuine equivalent mutations: each class in the when clause (NilClass/Symbol/Integer/Float/TrueClass/FalseClass) can be removed or replaced with nil because all those types are frozen so the else-branch val.frozen? guard returns the same result; return val vs val is also equivalent; if val.frozen? vs if self.frozen? is equivalent since self is never frozen in this context
    def deep_dup_value(val)
      case val
      when Array
        val.map { |v| deep_dup_value(v) }
      when Hash
        val.each_with_object({}) { |(k, v), h| h[k] = deep_dup_value(v) }
      when NilClass, Symbol, Integer, Float, TrueClass, FalseClass
        val
      else
        return val if val.frozen?

        begin
          val.dup
        rescue TypeError
          val
        end
      end
    end
  end
end
