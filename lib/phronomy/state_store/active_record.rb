# frozen_string_literal: true

require "json"

module Phronomy
  module StateStore
    # ActiveRecord-backed state store.
    # Persists graph state to a relational database using an AR model.
    #
    # The model_class must respond to:
    #   .find_by(thread_id:)
    #   .find_or_initialize_by(thread_id:)
    #   #state_json=, #save!
    #   .where(thread_id:).delete_all
    #
    # Minimal migration:
    #   create_table :phronomy_states do |t|
    #     t.string  :thread_id, null: false, index: { unique: true }
    #     t.text    :state_json, null: false
    #     t.timestamps
    #   end
    #
    # @example
    #   Phronomy.configure do |c|
    #     c.default_state_store = Phronomy::StateStore::ActiveRecord.new(
    #       model_class: PhronomyState
    #     )
    #   end
    class ActiveRecord < Base
      # @param model_class [Class] ActiveRecord model with the schema above.
      # @param encryptor [Phronomy::StateStore::Encryptor::Base, nil]
      #   Optional encryption adapter. When supplied, the JSON payload is
      #   encrypted before writing and decrypted after reading.
      #   When nil (default), data is stored as plain JSON.
      def initialize(model_class:, encryptor: nil)
        @model_class = model_class
        @encryptor = encryptor
      end

      # Serializes and upserts the state for the given thread_id.
      # @param state [Object] includes Phronomy::Graph::Context
      # @return [self]
      def save(state)
        json = serialize_state(state)
        payload = @encryptor ? @encryptor.encrypt(json) : json
        # Use upsert to avoid a race condition where two concurrent saves for the
        # same thread_id would both see "no record" and collide on the unique index.
        @model_class.upsert(
          {thread_id: state.thread_id, state_json: payload},
          unique_by: :thread_id,
          update_only: [:state_json]
        )
        self
      end

      # Loads and deserializes the state for the given thread_id.
      # @param thread_id [String]
      # @return [Object, nil] state instance or nil
      def load(thread_id)
        record = @model_class.find_by(thread_id: thread_id)
        return nil unless record

        payload = record.state_json
        json = @encryptor ? @encryptor.decrypt(payload) : payload
        deserialize_state(json)
      end

      # Deletes the state for the given thread_id.
      # @return [self]
      def clear(thread_id)
        @model_class.where(thread_id: thread_id).delete_all
        self
      end
    end
  end
end
