# frozen_string_literal: true

require_relative "schema"

module Phronomy
  module Tool
    # A request is a value, not an executable capability or an approval grant.
    # @api public
    class CallRequest
      attr_reader :id, :name, :arguments, :metadata

      # @api public
      def initialize(id:, name:, arguments:, metadata: {})
        unless id.is_a?(String) && !id.empty? && name.is_a?(String) && !name.empty?
          raise ArgumentError, "Tool request requires non-empty String id and name"
        end
        unless arguments.is_a?(Hash) && metadata.is_a?(Hash)
          raise ArgumentError, "Tool arguments and metadata must be Hashes"
        end
        @id = id.dup.freeze
        @name = name.dup.freeze
        @arguments = Phronomy::Values::Immutable.copy(Schema.json_value(arguments))
        @metadata = Phronomy::Values::Immutable.copy(Schema.json_value(metadata))
        freeze
      end

      # @api public
      def self.from_h(value)
        source = Schema.json_value(value)
        new(id: source.fetch("id"), name: source.fetch("name"),
          arguments: source.fetch("arguments"), metadata: source.fetch("metadata", {}))
      end

      # @api public
      def to_h
        {"id" => id, "name" => name, "arguments" => arguments, "metadata" => metadata}
      end
    end
  end
end
