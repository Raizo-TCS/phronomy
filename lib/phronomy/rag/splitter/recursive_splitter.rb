# frozen_string_literal: true

module Phronomy
  module RAG
    module Splitter
      # Splits text recursively using a prioritised list of separator strings.
      #
      # The splitter tries each separator in order.  When a separator produces
      # chunks that are still larger than +chunk_size+, it recurses with the
      # next separator in the list.  This mirrors LangChain's
      # RecursiveCharacterTextSplitter behaviour.
      #
      # Default separators (in priority order):
      #   1. "\n\n"  — paragraph breaks
      #   2. "\n"    — line breaks
      #   3. ". "    — sentence boundaries
      #   4. " "     — word boundaries
      #   5. ""      — character-level fallback
      #
      # @example
      #   splitter = Phronomy::RAG::Splitter::RecursiveSplitter.new(chunk_size: 300, chunk_overlap: 30)
      #   chunks   = splitter.split({ text: long_markdown, metadata: { source: "guide.md" } })
      class RecursiveSplitter < Base
        DEFAULT_SEPARATORS = ["\n\n", "\n", ". ", " ", ""].freeze

        # @param chunk_size    [Integer] maximum characters per chunk (default: 1000)
        # @param chunk_overlap [Integer] overlap characters (default: 200)
        # @param separators    [Array<String>] separator list in priority order
        # @api public
        def initialize(chunk_size: 1000, chunk_overlap: 200, separators: DEFAULT_SEPARATORS)
          raise ArgumentError, "chunk_overlap must be less than chunk_size" if chunk_overlap >= chunk_size

          @chunk_size = chunk_size
          @chunk_overlap = chunk_overlap
          @separators = separators
        end

        # @param document [Hash, String]
        # @return [Array<Hash>]
        # @api public
        def split(document)
          doc = normalise(document)
          texts = recursive_split(doc[:text], @separators)
          merge_with_overlap(texts).each_with_index.map do |text, idx|
            {text: text, metadata: doc[:metadata].merge(chunk: idx)}
          end
        end

        private

        # Split +text+ using the first separator that yields non-trivial pieces,
        # then recurse on any piece that is still too large.
        def recursive_split(text, separators)
          return [text] if text.length <= @chunk_size || separators.empty?

          sep, *rest_seps = separators

          # Character-level fallback: just slice
          if sep == ""
            return FixedSizeSplitter
                .new(chunk_size: @chunk_size, chunk_overlap: @chunk_overlap)
                .split(text)
                .map { |c| c[:text] }
          end

          parts = text.split(sep)

          # If this separator doesn't split, try the next
          return recursive_split(text, rest_seps) if parts.length <= 1

          # Re-attach the separator to each part except the last so context is preserved
          parts_with_sep = parts.each_with_index.map do |part, i|
            (i < parts.length - 1) ? part + sep : part
          end

          parts_with_sep.flat_map do |part|
            if part.length > @chunk_size
              recursive_split(part, rest_seps)
            else
              [part]
            end
          end.reject { |t| t.strip.empty? }
        end

        # Merge small adjacent pieces and apply overlap between chunks.
        def merge_with_overlap(texts)
          merged = []
          current = +""

          texts.each do |text|
            if current.length + text.length <= @chunk_size
              current << text
            else
              merged << current.strip unless current.strip.empty?
              # Start next chunk with overlap from the end of current
              overlap_text = (current.length > @chunk_overlap) ? current[-@chunk_overlap..] : current
              current = overlap_text + text
            end
          end

          merged << current.strip unless current.strip.empty?
          merged
        end
      end
    end
  end
end
