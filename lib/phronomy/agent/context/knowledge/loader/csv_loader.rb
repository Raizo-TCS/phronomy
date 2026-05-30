# frozen_string_literal: true

require "csv"

module Phronomy
  module Agent
    module Context
      module Knowledge
        module Loader
    # Loads a CSV file, converting each row into a separate document.
    #
    # By default the first row is treated as a header and column names are
    # available in the document metadata.  The full row is serialised to
    # a human-readable "key: value" string for embedding.
    #
    # @example
    #   loader = Phronomy::Agent::Context::Knowledge::Loader::CsvLoader.new
    #   docs   = loader.load("products.csv")
    #   # => [
    #   #   { text: "name: Widget\nprice: 9.99", metadata: { source: "...", row: 1, name: "Widget", price: "9.99" } },
    #   #   ...
    #   # ]
    class CsvLoader < Base
      # @param headers     [Boolean] treat the first row as headers (default: true)
      # @param text_column [String, nil] if set, use only this column as the document text
      # @api public
      def initialize(headers: true, text_column: nil)
        @headers = headers
        @text_column = text_column
      end

      # @param source [String] path to a CSV file
      # @return [Array<Hash>]
      # @raise [Errno::ENOENT] if the file does not exist
      # @api public
      def load(source)
        rows = CSV.read(source, headers: @headers, encoding: "UTF-8")

        if @headers
          rows.each_with_index.map do |row, idx|
            row_hash = row.to_h
            text = if @text_column
              row_hash[@text_column].to_s
            else
              row_hash.map { |k, v| "#{k}: #{v}" }.join("\n")
            end
            metadata = row_hash.transform_keys(&:to_sym).merge(source: source, row: idx + 1)
            {text: text, metadata: metadata}
          end
        else
          rows.each_with_index.map do |row, idx|
            text = row.join(", ")
            {text: text, metadata: {source: source, row: idx + 1}}
          end
        end
      end
    end
  end
end
end
end
end
