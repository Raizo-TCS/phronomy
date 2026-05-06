# frozen_string_literal: true

module Phronomy
  module OutputParser
    # Parses JSON and maps it to an instance of the given schema class.
    # @example
    #   PersonSchema = Struct.new(:name, :age, keyword_init: true)
    #   parser = Phronomy::OutputParser::StructuredParser.new(PersonSchema)
    #   parser.parse('{"name":"Alice","age":30}')  #=> #<struct PersonSchema name="Alice", age=30>
    class StructuredParser < Base
      # @param schema_class [Class] Struct with keyword_init: true or equivalent
      def initialize(schema_class)
        @schema_class = schema_class
      end

      # @param text [String]
      # @return [Object] instance of schema_class
      # @raise [Phronomy::ParseError] raised when JSON parsing or schema instantiation fails
      def parse(text)
        data = JsonParser.new.parse(text)
        @schema_class.new(**data)
      rescue ArgumentError, TypeError => e
        raise Phronomy::ParseError, "Failed to map to schema: #{e.message}"
      end
    end
  end
end
