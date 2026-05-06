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
    end
  end
end
