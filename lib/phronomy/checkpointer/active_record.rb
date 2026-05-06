# frozen_string_literal: true

require "json"

module Phronomy
  module Checkpointer
    # ActiveRecord-backed checkpointer.
    # Persists graph state to a relational database using an AR model.
    #
    # The model_class must respond to:
    #   .find_by(thread_id:)
    #   .find_or_initialize_by(thread_id:)
    #   #state_json=, #interrupted_at=, #completed_node=, #save!
    #   .where(thread_id:).delete_all
    #
    # @example
    #   checkpointer = Phronomy::Checkpointer::ActiveRecord.new(
    #     model_class: PhronomyCheckpoint
    #   )
    #   graph.compile(checkpointer: checkpointer)
    class ActiveRecord < Base
      # @param model_class [Class] ActiveRecord model with the phronomy_checkpoints schema.
      def initialize(model_class:)
        @model_class = model_class
      end

      # Serializes and upserts the checkpoint for the given thread_id.
      # @param thread_id [String]
      # @param state [Object] an object that includes Phronomy::Graph::State
      # @param interrupted_at [Symbol, nil]
      # @param completed_node [Symbol, nil]
      # @return [self]
      def save(thread_id, state, interrupted_at: nil, completed_node: nil)
        json = serialize_state(state)
        record = @model_class.find_or_initialize_by(thread_id: thread_id)
        record.state_json      = json
        record.interrupted_at  = interrupted_at&.to_s
        record.completed_node  = completed_node&.to_s
        record.save!
        self
      end

      # Loads and deserializes the checkpoint for the given thread_id.
      # @param thread_id [String]
      # @return [Checkpoint, nil]
      def load(thread_id)
        record = @model_class.find_by(thread_id: thread_id)
        return nil unless record

        deserialize_checkpoint(record)
      end

      # Deletes the checkpoint for the given thread_id.
      # @return [self]
      def clear(thread_id)
        @model_class.where(thread_id: thread_id).delete_all
        self
      end

      private

      def serialize_state(state)
        JSON.generate(
          state_class: state.class.name,
          state_data:  state.to_h
        )
      end

      def deserialize_checkpoint(record)
        data        = JSON.parse(record.state_json, symbolize_names: true)
        state_class = Object.const_get(data[:state_class])
        # Symbolize nested keys so field names resolve correctly.
        state_data  = symbolize_keys(data[:state_data])
        state       = state_class.new(**state_data)

        Phronomy::Checkpointer::Checkpoint.new(
          state:          state,
          interrupted_at: record.interrupted_at&.to_sym,
          completed_node: record.completed_node&.to_sym
        )
      end

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
