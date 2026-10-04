# frozen_string_literal: true

require "json_schemer"
require "schematist"
require_relative "../common/values/immutable"

module Phronomy
  module Tool
    # One schema defines both the advertised arguments and runtime validation.
    # Schema evaluation is local: remote references and custom vocabularies are
    # not supported. Provider request rendering does not belong to this class.
    # @api public
    class Schema
      KEYWORDS = %w[
        $schema $ref $defs $comment definitions
        type enum const title description default examples deprecated readOnly writeOnly
        properties patternProperties additionalProperties required propertyNames
        minProperties maxProperties dependentRequired dependentSchemas
        items prefixItems contains minContains maxContains
        minItems maxItems uniqueItems minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
        minLength maxLength pattern format allOf anyOf oneOf not if then else
        unevaluatedProperties unevaluatedItems strict
      ].freeze
      FORMATS = %w[date-time date time duration email idn-email hostname idn-hostname ipv4 ipv6 uri uri-reference iri iri-reference uuid uri-template json-pointer relative-json-pointer regex].freeze
      SCHEMA_MAPS = %w[properties patternProperties $defs definitions dependentSchemas].freeze
      SCHEMA_LISTS = %w[allOf anyOf oneOf prefixItems].freeze
      SCHEMA_VALUES = %w[additionalProperties propertyNames items contains not if then else unevaluatedProperties unevaluatedItems].freeze

      # @api public
      def initialize(schema = nil, &block)
        source = if block
          raise ArgumentError, "pass either a schema or a block" unless schema.nil?
          Schematist::Schema.create(&block).new.to_json_schema
        elsif schema.is_a?(Class) && schema.method_defined?(:to_json_schema)
          schema.new.to_json_schema
        elsif schema.respond_to?(:to_json_schema)
          schema.to_json_schema
        else
          schema
        end
        source = source[:schema] || source["schema"] || source if source.is_a?(Hash)
        @json_schema = self.class.json_value(source)
        unless @json_schema.is_a?(Hash) && @json_schema["type"] == "object"
          raise ArgumentError, "Tool schema must declare an object"
        end
        @references = []
        validate_keywords!(@json_schema)
        options = {ref_resolver: ->(uri) { raise ArgumentError, "external Tool schema reference: #{uri}" }}
        unless JSONSchemer.valid_schema?(@json_schema, **options)
          raise ArgumentError, "invalid Tool JSON Schema"
        end
        @json_schema = Phronomy::Values::Immutable.copy(@json_schema)
        @validator = JSONSchemer.schema(@json_schema, **options)
        @references.each { |reference| @validator.ref(reference) }
        @references = nil
        freeze
      rescue JSONSchemer::InvalidRefPointer, JSONSchemer::InvalidRefResolution => error
        raise ArgumentError, "invalid local Tool schema reference: #{error.message}"
      end

      # @api public
      attr_reader :json_schema

      # Return validated keyword arguments without modifying the caller's values.
      # Coercion is limited to explicit property/item types; combinators and
      # references are validated without guessing a branch or resolving a cast.
      # @api public
      def validate(arguments, coerce: false)
        return [nil, "arguments must be an object (Hash)"] unless arguments.is_a?(Hash)
        data = self.class.json_value(arguments)
        data = self.class.json_value(coerce_value(data, @json_schema)) if coerce
        error = @validator.validate(data).first
        return [nil, error_message(error)] if error
        [restore_keys(arguments, data).transform_keys(&:to_sym), nil]
      rescue ArgumentError, TypeError => error
        [nil, error.message]
      end

      # JSON values, with duplicate normalized keys rejected instead of lost.
      # @api private
      def self.json_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ArgumentError, "Tool object keys must be Strings or Symbols"
            end
            name = key.to_s
            raise ArgumentError, "duplicate Tool object key: #{name}" if result.key?(name)
            result[name] = json_value(child)
          end
        when Array then value.map { |child| json_value(child) }
        when String, Integer, TrueClass, FalseClass, NilClass then value
        when Float
          raise ArgumentError, "Tool numbers must be finite" unless value.finite?
          value
        else
          raise ArgumentError, "unsupported Tool value: #{value.class}"
        end
      end

      private

      def error_message(error)
        path = error.fetch("data_pointer", "").split("/").drop(1)
        field = path.join(".")
        type = error["type"]
        type = "additionalProperties" if error["schema"] == false && error["schema_pointer"].end_with?("/additionalProperties")
        case type
        when "required"
          key = Array(error.dig("details", "missing_keys")).first
          path.empty? ? "required parameter '#{key}' is missing" : "nested required field '#{field}.#{key}' is missing"
        when "additionalProperties"
          (path.size > 1) ? "nested field '#{path[0...-1].join(".")}' contains undeclared key(s): #{path.last.inspect}" : "unknown parameter(s): #{path.last.inspect}"
        when "enum"
          "parameter '#{field}' must be one of: #{Array(error.dig("schema", "enum")).join(", ")} (got: #{error["data"].inspect})"
        when "string", "integer", "number", "boolean", "object", "array", "null"
          prefix = (path.size > 1) ? "nested field '#{field}'" : "parameter '#{field}'"
          "#{prefix} expected type #{type} (got: #{error["data"].inspect})"
        else
          error.fetch("error", "invalid Tool arguments")
        end
      end

      def validate_keywords!(schema)
        return if schema == true || schema == false
        raise ArgumentError, "invalid Tool schema node" unless schema.is_a?(Hash)
        unknown = schema.keys - KEYWORDS
        raise ArgumentError, "unsupported Tool schema keywords: #{unknown.join(", ")}" unless unknown.empty?
        if schema.key?("$schema") && schema["$schema"] != "https://json-schema.org/draft/2020-12/schema"
          raise ArgumentError, "Tool schemas require JSON Schema 2020-12"
        end
        if schema.key?("format") && !FORMATS.include?(schema["format"])
          raise ArgumentError, "unsupported Tool schema format: #{schema["format"]}"
        end
        if schema.key?("$ref")
          reference = schema["$ref"]
          if !(reference.is_a?(String) && (reference == "#" || reference.start_with?("#/")))
            raise ArgumentError, "Tool schemas support local JSON Pointer references only"
          end
          @references << reference
        end
        SCHEMA_MAPS.each do |key|
          next unless schema.key?(key)
          raise ArgumentError, "#{key} must be an object" unless schema[key].is_a?(Hash)
          schema[key].each_value { |child| validate_keywords!(child) }
        end
        SCHEMA_LISTS.each do |key|
          next unless schema.key?(key)
          raise ArgumentError, "#{key} must be an array" unless schema[key].is_a?(Array)
          schema[key].each { |child| validate_keywords!(child) }
        end
        SCHEMA_VALUES.each { |key| validate_keywords!(schema[key]) if schema.key?(key) }
      end

      def coerce_value(value, schema)
        return value unless schema.is_a?(Hash)
        return value if (schema.keys & %w[$ref anyOf oneOf allOf not if]).any?
        type = schema["type"]
        if type.is_a?(Array)
          alternatives = type - ["null"]
          type = alternatives.first if alternatives.length == 1
        end
        case type
        when "object"
          return value unless value.is_a?(Hash)
          value.to_h { |key, child| [key, coerce_value(child, schema.fetch("properties", {}).fetch(key, {}))] }
        when "array"
          return value unless value.is_a?(Array)
          value.map { |child| coerce_value(child, schema.fetch("items", {})) }
        when "string" then value.nil? ? value : value.to_s
        when "integer"
          return value if value.nil? || value.is_a?(Integer)
          raise ArgumentError, "fractional Tool value cannot be coerced to integer" if value.is_a?(Numeric) && value != value.to_i
          begin
            Integer(value)
          rescue ArgumentError, TypeError
            raise ArgumentError, "parameter cannot be coerced to integer: #{value.inspect}"
          end
        when "number"
          begin
            value.nil? ? value : Float(value)
          rescue ArgumentError, TypeError
            raise ArgumentError, "parameter cannot be coerced to number: #{value.inspect}"
          end
        when "boolean"
          case value
          when true, false, nil then value
          else
            case value.to_s.downcase
            when "true" then true
            when "false" then false
            else raise ArgumentError, "parameter cannot be coerced to boolean: #{value.inspect}"
            end
          end
        else value
        end
      end

      def restore_keys(original, value)
        case value
        when Hash
          value.to_h do |key, child|
            old_key = (original.is_a?(Hash) && original.key?(key.to_sym)) ? key.to_sym : key
            [old_key, restore_keys(original.is_a?(Hash) ? original[old_key] : nil, child)]
          end
        when Array
          value.each_with_index.map { |child, index| restore_keys(original.is_a?(Array) ? original[index] : nil, child) }
        else value
        end
      end
    end
  end
end
