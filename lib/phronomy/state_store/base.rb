# frozen_string_literal: true

module Phronomy
  module StateStore
    # Abstract base class for workflow state persistence backends.
    #
    # Subclasses must implement {#load}, {#save}, and {#delete}.
    # A snapshot is a plain +Hash+ with two keys:
    #   +:fields+ — output of +context.to_h+
    #   +:phase+  — +context.phase.to_s+
    #
    # @example Implementing a custom backend
    #   class MyStore < Phronomy::StateStore::Base
    #     def load(thread_id) = MyRecord.find_by(thread_id:)&.to_h
    #     def save(thread_id, snapshot) = MyRecord.upsert(thread_id:, data: snapshot)
    #     def delete(thread_id) = MyRecord.where(thread_id:).delete_all
    #   end
    class Base
      # Load the stored snapshot for +thread_id+.
      #
      # @param thread_id [String]
      # @return [Hash, nil] stored snapshot hash, or +nil+ if absent
      # @api public
      def load(thread_id)
        raise NotImplementedError, "#{self.class}#load is not implemented"
      end

      # Persist +snapshot+ for +thread_id+. Overwrites any existing snapshot.
      #
      # @param thread_id [String]
      # @param snapshot [Hash] serialisable hash of workflow state
      # @return [void]
      # @api public
      def save(thread_id, snapshot)
        raise NotImplementedError, "#{self.class}#save is not implemented"
      end

      # Delete the stored snapshot for +thread_id+. No-op if absent.
      #
      # @param thread_id [String]
      # @return [void]
      # @api public
      def delete(thread_id)
        raise NotImplementedError, "#{self.class}#delete is not implemented"
      end
    end
  end
end
