# frozen_string_literal: true

module Phronomy
  module Loader
    # Loads a plain-text file as a single document.
    #
    # @example
    #   loader = Phronomy::Loader::PlainTextLoader.new
    #   docs   = loader.load("/path/to/file.txt")
    #   # => [{ text: "...", metadata: { source: "/path/to/file.txt" } }]
    class PlainTextLoader < Base
      # @param source [String] absolute or relative path to a text file
      # @return [Array<Hash>] single-element array with the file contents
      # @raise [Errno::ENOENT] if the file does not exist
      # @api public
      def load(source)
        text = File.read(source, encoding: "UTF-8")
        [{text: text, metadata: {source: source}}]
      end
    end
  end
end
