# frozen_string_literal: true

require "json"

module Phronomy
  module StateStore
    # Abstract base class for state persistence backends.
    # Subclasses must implement save, load, and clear.
    #
    # The state object passed to save must include Phronomy::Graph::State
    # and have a non-nil thread_id (set automatically by CompiledGraph#invoke).
    class Base
      # Persists the state. The thread_id is read from state.thread_id.
      # @param state [Object] object including Phronomy::Graph::State
      # @return [self]
      def save(state)
        raise NotImplementedError, "#{self.class}#save is not implemented"
      end

      # Loads the state for the given thread_id.
      # @param thread_id [String]
      # @return [Object, nil] state object or nil if not found
      def load(thread_id)
        raise NotImplementedError, "#{self.class}#load is not implemented"
      end

      # Removes the saved state for the given thread_id.
      # @param thread_id [String]
      # @return [self]
      def clear(thread_id)
        raise NotImplementedError, "#{self.class}#clear is not implemented"
      end

      private

      # Serializes a state object to a JSON string.
      # Includes user-defined fields and internal graph metadata.
      def serialize_state(state)
        JSON.generate(
          state_class: state.class.name,
          state_data: json_safe(state.to_h),
          thread_id: state.thread_id,
          current_nodes: state.current_nodes&.map(&:to_s),
          halted_before: state.halted_before
        )
      end

      # Deserializes a JSON string back into a state object.
      # @return [Object] state instance with graph metadata restored
      def deserialize_state(json_str)
        data = JSON.parse(json_str, symbolize_names: true)
        state_class = safe_state_class(data[:state_class])
        state_data = symbolize_keys(data[:state_data])
        state = state_class.new(**state_data)
        state.set_graph_metadata(
          thread_id: data[:thread_id],
          current_nodes: data[:current_nodes]&.map(&:to_sym),
          halted_before: data[:halted_before]
        )
        state
      end

      # Resolves and validates a state class name.
      # When a registry has been configured via +Phronomy::Graph.register_state_class+,
      # only registered classes are accepted — this prevents unintended autoloading
      # of arbitrary files from an untrusted class name stored in Redis/DB.
      # When no registry is configured, falls back to Object.const_get with a check
      # that the resolved class includes Phronomy::Graph::State.
      def safe_state_class(class_name)
        registry = Phronomy::Graph.state_class_registry
        if registry
          klass = registry[class_name.to_s]
          unless klass
            raise ArgumentError,
              "Unregistered state class: #{class_name.inspect}. " \
              "Call Phronomy::Graph.register_state_class(#{class_name}) at startup."
          end
          return klass
        end

        klass = Object.const_get(class_name.to_s)
        unless klass.is_a?(Class) && klass.include?(Phronomy::Graph::State)
          raise ArgumentError, "Invalid state class: #{class_name.inspect}"
        end
        klass
      rescue NameError
        raise ArgumentError, "Unknown state class: #{class_name.inspect}"
      end

      # Recursively converts objects to JSON-safe primitives.
      def json_safe(obj)
        case obj
        when Hash
          obj.transform_keys(&:to_s).transform_values { |v| json_safe(v) }
        when Array
          obj.map { |v| json_safe(v) }
        when String, Numeric, TrueClass, FalseClass, NilClass
          obj
        else
          obj.respond_to?(:to_h) ? json_safe(obj.to_h) : obj.to_s
        end
      end

      # Recursively symbolizes hash keys.
      def symbolize_keys(obj)
        case obj
        when Hash then obj.transform_keys(&:to_sym).transform_values { |v| symbolize_keys(v) }
        when Array then obj.map { |v| symbolize_keys(v) }
        else obj
        end
      end
    end
  end
end
