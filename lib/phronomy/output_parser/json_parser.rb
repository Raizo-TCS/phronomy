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
      # @api public
      def parse(text)
        json_str = extract_json(text)
        JSON.parse(json_str, symbolize_names: true)
      rescue JSON::ParserError => e
        raise Phronomy::ParseError, "Failed to parse JSON: #{e.message}\nInput: #{text}"
      end

      private

      # Extracts a JSON string from the LLM response text.
      #
      # Strategy (in order):
      #   1. Try each ```json ... ``` or ``` ... ``` code fence in document order,
      #      returning the content of the first one that parses as valid JSON.
      #   2. Try the raw text stripped of leading/trailing whitespace.
      #
      # This handles:
      #   - Single JSON code fence (common case)
      #   - Multiple code fences — the first parseable JSON block wins
      #   - No fence — LLM omitted the backticks but returned valid JSON
      def extract_json(text)
        text.scan(/```(?:json)?\s*\n?(.*?)\n?```/m).each do |captures|
          candidate = captures.first.strip
          JSON.parse(candidate)
          return candidate
        rescue JSON::ParserError
          next
        end

        # Fallback: no valid fence found — try the raw text
        text.strip
      end
    end
  end
end
