# frozen_string_literal: true

module Phronomy
  module Eval
    # An ordered collection of EvalCase objects.
    #
    # @example Build from a plain array of hashes
    #   dataset = Dataset.from_array([
    #     { input: "What is 2+2?", expected: "4" },
    #     { input: "Capital of France?", expected: "Paris" }
    #   ])
    class Dataset
      include Enumerable

      # @param cases [Array<EvalCase>]
      # @api public
      def initialize(cases = [])
        @cases = cases.freeze
      end

      # Constructs a Dataset from an Array of Hash-like objects.
      # Each hash must have at least +:input+ and +:expected+ keys.
      # An optional +:metadata+ key is forwarded as-is.
      #
      # @param pairs [Array<Hash>]
      # @return [Dataset]
      # @api public
      def self.from_array(pairs)
        new(pairs.map { |h| EvalCase.new(**h) })
      end

      # @yield [EvalCase]
      # @api public
      def each(&block)
        @cases.each(&block)
      end

      # @return [Integer]
      # @api public
      def size
        @cases.size
      end
    end
  end
end
