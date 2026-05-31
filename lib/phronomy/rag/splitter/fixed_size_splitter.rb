# frozen_string_literal: true

module Phronomy
  module RAG
    module Splitter
      # Splits text into fixed-size character chunks with optional overlap.
      #
      # @example
      #   splitter = Phronomy::RAG::Splitter::FixedSizeSplitter.new(chunk_size: 200, chunk_overlap: 20)
      #   chunks   = splitter.split({ text: long_text, metadata: { source: "doc.txt" } })
      #   # => [
      #   #   { text: "...(200 chars)...", metadata: { source: "doc.txt", chunk: 0 } },
      #   #   { text: "...(200 chars, 20-char overlap)...", metadata: { source: "doc.txt", chunk: 1 } },
      #   # ]
      class FixedSizeSplitter < Base
        # @param chunk_size    [Integer] maximum characters per chunk (default: 1000)
        # @param chunk_overlap [Integer] characters to repeat at the start of each
        #   subsequent chunk (default: 200); must be less than chunk_size
        # @api public
        def initialize(chunk_size: 1000, chunk_overlap: 200)
          raise ArgumentError, "chunk_overlap must be less than chunk_size" if chunk_overlap >= chunk_size

          @chunk_size = chunk_size
          @chunk_overlap = chunk_overlap
        end

        # @param document [Hash, String]
        # @return [Array<Hash>]
        # @api public
        def split(document)
          doc = normalise(document)
          text = doc[:text]
          base_metadata = doc[:metadata]

          chunks = []
          start = 0
          index = 0

          while start < text.length
            chunk_text = text[start, @chunk_size]
            chunks << {text: chunk_text, metadata: base_metadata.merge(chunk: index)}
            break if start + @chunk_size >= text.length

            start += @chunk_size - @chunk_overlap
            index += 1
          end

          chunks
        end
      end
    end
  end
end
