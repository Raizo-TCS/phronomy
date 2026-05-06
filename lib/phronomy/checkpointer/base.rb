# frozen_string_literal: true

module Phronomy
  module Checkpointer
    # Data structure for a single checkpoint.
    Checkpoint = Struct.new(:state, :interrupted_at, :completed_node, keyword_init: true)

    class Base
      def save(thread_id, state, **metadata)
        raise NotImplementedError, "#{self.class}#save is not implemented"
      end

      def load(thread_id)
        raise NotImplementedError, "#{self.class}#load is not implemented"
      end

      def clear(thread_id)
        raise NotImplementedError, "#{self.class}#clear is not implemented"
      end

      private

      # Converts state to a JSON-safe hash.
      # State fields may contain RubyLLM::Message / RubyLLM::ToolCall objects —
      # we call to_h recursively to convert them before JSON serialization.
      def serialize_state(state)
        JSON.generate(
          state_class: state.class.name,
          state_data:  json_safe(state.to_h)
        )
      end

      # Deserializes state_data JSON back into state field values.
      # Symbolizes keys so Phronomy::Graph::State field names resolve correctly.
      def deserialize_state_data(json_str)
        data        = JSON.parse(json_str, symbolize_names: true)
        state_class = Object.const_get(data[:state_class])
        state_data  = symbolize_keys(data[:state_data])
        [state_class, state_data]
      end

      # Recursively converts objects to JSON-safe primitives.
      # Objects responding to to_h (e.g. RubyLLM::Message, RubyLLM::ToolCall)
      # are converted via to_h before serialization.
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

      # Recursively symbolize hash keys for State struct reconstruction.
      def symbolize_keys(obj)
        case obj
        when Hash  then obj.transform_keys(&:to_sym).transform_values { |v| symbolize_keys(v) }
        when Array then obj.map { |v| symbolize_keys(v) }
        else obj
        end
      end
    end
  end
end
