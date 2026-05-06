# frozen_string_literal: true

require "json"

module Phronomy
  module OutputParser
    # Extracts and parses JSON from LLM response text.
    # Automatically handles Markdown code fences (```json ... ```).
    class JsonParser < Base
      # @param text [String]
      # @return [Hash, Array] result parsed with symbolize_names: true
      # @raise [Phronomy::ParseError] raised when JSON parsing fails
      def parse(text)
        json_str = extract_json(text)
        JSON.parse(json_str, symbolize_names: true)
      rescue JSON::ParserError => e
        raise Phronomy::ParseError, "Failed to parse JSON: #{e.message}\nInput: #{text}"
      end

      private

      # Extracts the inner content of a Markdown code fence if present;
      # otherwise returns the text as-is.
      def extract_json(text)
        text.match(/```(?:json)?\s*\n?(.*?)\n?```/m)&.captures&.first || text.strip
      end
    end
  end
end
