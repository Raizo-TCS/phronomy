# frozen_string_literal: true

module Phronomy
  module Memory
    module Compression
      # Abstract base class for compression strategies.
      #
      # @abstract Subclass and implement #compress.
      class Base
        # Compress a message array and return a (possibly smaller) message array.
        #
        # @param thread_id [String]  thread identifier (used by stateful compressors)
        # @param messages  [Array]   full message history to compress
        # @return [Array] compressed message array
        def compress(thread_id:, messages:)
          raise NotImplementedError, "#{self.class}#compress is not implemented"
        end
      end
    end
  end
end
