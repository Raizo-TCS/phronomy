# frozen_string_literal: true

module Phronomy
  module Memory
    class Base
      def load_messages(thread_id:, **_options)
        raise NotImplementedError, "#{self.class}#load_messages is not implemented"
      end

      def save_messages(thread_id:, messages:)
        raise NotImplementedError, "#{self.class}#save_messages is not implemented"
      end

      def clear(thread_id:)
        raise NotImplementedError, "#{self.class}#clear is not implemented"
      end
    end
  end
end
