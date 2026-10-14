# frozen_string_literal: true

require "json"
require "json_schemer"
require "uri"
require_relative "../common/values/immutable"

module Phronomy
  module OutputParser
    # Strict JSON decoding and validation, without extraction or value coercion.
    # @api public
    class JsonSchemaParser < Base
      KEYWORDS = %w[$schema $defs $ref title description type enum const anyOf
        properties required additionalProperties items minItems maxItems minimum
        maximum exclusiveMinimum exclusiveMaximum multipleOf minLength maxLength pattern].freeze
      private_constant :KEYWORDS

      # @api public
      attr_reader :json_schema

      # @api public
      def initialize(schema:)
        @json_schema = Phronomy::Values::Immutable.json(schema)
        unless @json_schema.is_a?(Hash) && @json_schema["type"] == "object"
          raise ArgumentError, "output schema must declare a root object"
        end
        validate_node!(@json_schema, [])
        options = {ref_resolver: ->(_uri) { raise ArgumentError, "external output schema reference" }}
        unless JSONSchemer.valid_schema?(@json_schema, **options)
          raise ArgumentError, "invalid output JSON Schema"
        end
        @validator = JSONSchemer.schema(@json_schema, **options)
        freeze
      end

      # @api public
      def parse(text)
        value = decode(text)
        violations = @validator.validate(value).map do |error|
          {"pointer" => error.fetch("data_pointer", ""),
           "schema_pointer" => error.fetch("schema_pointer", ""),
           "keyword" => error.fetch("type", "schema")}
        end
        unless violations.empty?
          raise Phronomy::ParseError.new("Output does not satisfy its JSON schema",
            code: "output_parser.schema_mismatch", details: violations)
        end
        value
      end

      private

      def decode(text)
        raise JSON::ParserError, "output must be JSON text" unless text.is_a?(String)
        Phronomy::Values::Immutable.json(JSON.parse(text, allow_duplicate_key: false, allow_nan: false, allow_comments: false, allow_invalid_escape: false, allow_control_characters: false))
      rescue JSON::ParserError, ArgumentError
        raise Phronomy::ParseError.new("Output is not strict JSON",
          code: "output_parser.invalid_json", details: [{"pointer" => "", "keyword" => "json"}]), cause: nil
      end

      def validate_node!(node, ancestors)
        return if node == true || node == false
        raise ArgumentError, "invalid output schema node" unless node.is_a?(Hash)
        raise ArgumentError, "cyclic output schema reference" if ancestors.include?(node.object_id)
        ancestors += [node.object_id]
        unknown = node.keys - KEYWORDS
        raise ArgumentError, "unsupported output schema keywords: #{unknown.join(", ")}" unless unknown.empty?
        if node.key?("$schema") && node["$schema"] != "https://json-schema.org/draft/2020-12/schema"
          raise ArgumentError, "output schemas require JSON Schema 2020-12"
        end
        if node.key?("pattern")
          raise ArgumentError, "pattern must be a String" unless node["pattern"].is_a?(String)
          begin
            Regexp.new(node["pattern"])
          rescue RegexpError
            raise ArgumentError, "invalid output schema pattern"
          end
        end
        %w[properties $defs].each do |key|
          next unless node.key?(key)
          raise ArgumentError, "#{key} must be an object" unless node[key].is_a?(Hash)
          node[key].each_value { |child| validate_node!(child, ancestors) }
        end
        if node.key?("anyOf")
          raise ArgumentError, "anyOf must be an array" unless node["anyOf"].is_a?(Array)
          node["anyOf"].each { |child| validate_node!(child, ancestors) }
        end
        %w[items additionalProperties].each do |key|
          validate_node!(node[key], ancestors) if node.key?(key)
        end
        validate_node!(resolve_reference(node["$ref"]), ancestors) if node.key?("$ref")
      end

      def resolve_reference(reference)
        valid = reference.is_a?(String) && (reference == "#" || reference.start_with?("#/"))
        unless valid
          raise ArgumentError, "output schemas support local JSON Pointer references only"
        end
        URI::DEFAULT_PARSER.unescape(reference.delete_prefix("#")).split("/", -1).drop(1).reduce(@json_schema) do |node, token|
          raise ArgumentError, "invalid output schema JSON Pointer" if token.match?(/~(?![01])/)
          key = token.gsub("~1", "/").gsub("~0", "~")
          if node.is_a?(Hash) && node.key?(key)
            node.fetch(key)
          elsif node.is_a?(Array) && key.match?(/\A(?:0|[1-9][0-9]*)\z/) && key.to_i < node.length
            node.fetch(key.to_i)
          else
            raise ArgumentError, "output schema reference does not exist"
          end
        end
      end
    end
  end
end
