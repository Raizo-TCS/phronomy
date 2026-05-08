# frozen_string_literal: true

module Phronomy
  module Tool
    # Base class extending RubyLLM::Tool with Phronomy-specific DSL.
    #
    # Additional DSL over RubyLLM::Tool:
    #   - tool_name         : explicit function name exposed to the LLM (overrides auto-conversion)
    #   - scope             : access-scope metadata (:read_only, :write, etc.)
    #   - on_error          : error-handling policy (:raise or :return_empty)
    #   - on_schema_error   : behavior when LLM passes schema-violating arguments
    #                         :return_error (default), :raise, or :coerce
    #   - requires_approval : require human approval before execution
    #   - param :name, enum: [...] : restrict allowed values in the JSON Schema
    #
    # @example
    #   class SearchKnowledgeBase < Phronomy::Tool::Base
    #     tool_name "search_kb"               # explicit name shown to the LLM
    #     description "Search the internal knowledge base"
    #     param :query,  type: :string, desc: "Search query"
    #     param :lang,   type: :string, desc: "Language", required: false, enum: %w[en ja fr]
    #     scope :read_only
    #     on_error :return_empty
    #
    #     def execute(query:, lang: "en")
    #       KnowledgeBase.search(query, lang: lang)
    #     end
    #   end
    class Base < RubyLLM::Tool
      class << self
        # Sets an explicit function name to expose to the LLM, bypassing RubyLLM's
        # automatic CamelCase-to-snake_case conversion.
        # When omitted, RubyLLM's default conversion applies (e.g. WeatherTool → "weather").
        #
        # @param value [String, nil] the exact function name the LLM will see
        def tool_name(value = nil)
          return @tool_name if value.nil?

          @tool_name = value.to_s
        end

        # Extends RubyLLM::Tool.param with an optional +enum:+ keyword.
        # The enum values are stored separately and injected into the JSON Schema
        # produced by #params_schema.
        #
        # @param name [Symbol] parameter name
        # @param enum [Array, nil] allowed values; when given, added as "enum" in JSON Schema
        # @param options [Hash] forwarded to RubyLLM::Tool.param
        def param(name, enum: nil, **options)
          super(name, **options)
          param_enums[name] = enum if enum
        end

        # Returns the enum constraints registered via .param.
        # @return [Hash{Symbol => Array}]
        def param_enums
          @param_enums ||= {}
        end

        # Sets the access scope for this tool (metadata; enforcement is the responsibility of
        # the Graph/Guardrail layer).
        # @param value [Symbol] e.g. :read_only, :write, :admin
        def scope(value = nil)
          return @scope if value.nil?

          @scope = value
        end

        # Configures error-handling behavior.
        # @param behavior [Symbol] :raise (default) or :return_empty
        def on_error(behavior = nil)
          return @on_error || :raise if behavior.nil?

          @on_error = behavior
        end

        # Configures how this tool responds when the LLM passes arguments that violate
        # the declared parameter types or enum constraints.
        #
        # @param behavior [Symbol]
        #   :return_error (default) — return a descriptive error string as the tool result
        #                             so the LLM can self-correct on the next turn.
        #   :raise                  — raise Phronomy::ToolError, stopping the agent loop.
        #   :coerce                 — attempt type coercion (e.g. "42" → 42 for :integer);
        #                             falls back to :return_error when coercion is not possible.
        def on_schema_error(behavior = nil)
          return @on_schema_error || :return_error if behavior.nil?

          @on_schema_error = behavior
        end

        # Configures whether human approval is required before executing this tool.
        # @param value [Boolean]
        def requires_approval(value = nil)
          return @requires_approval || false if value.nil?

          @requires_approval = value
        end
      end

      # Returns the function name exposed to the LLM.
      # Uses the class-level tool_name if set; otherwise falls back to RubyLLM's
      # automatic conversion (CamelCase → snake_case, strips trailing "_tool").
      def name
        self.class.tool_name || super
      end

      # Returns the JSON Schema for this tool's parameters.
      # Injects "enum" entries for any param declared with enum: [...].
      def params_schema
        schema = super
        return schema if schema.nil? || self.class.param_enums.empty?

        enums = self.class.param_enums
        properties = schema.dig("properties") || schema.dig(:properties)
        return schema unless properties

        enums.each do |param_name, values|
          key = properties.key?(param_name.to_s) ? param_name.to_s : param_name.to_sym
          next unless properties[key]

          properties[key]["enum"] = values.map(&:to_s)
        end

        schema
      end

      # Overrides RubyLLM::Tool#call to apply schema validation, the on_error policy,
      # and wrap errors as ToolError.
      #
      # Schema validation order:
      #   1. Type checking — verifies each argument matches its declared :type.
      #   2. Enum checking — verifies enum-constrained params are within allowed values.
      # When a violation is found, the on_schema_error policy decides the outcome.
      def call(args)
        validated_args, schema_error = validate_and_coerce(args)
        if schema_error
          case self.class.on_schema_error
          when :raise
            raise Phronomy::ToolError, "#{self.class.name} schema error: #{schema_error}"
          else
            # :return_error (default) and coerce fallback
            return "Schema validation failed: #{schema_error}"
          end
        end
        super(validated_args)
      rescue Phronomy::ToolError
        raise
      rescue => e
        case self.class.on_error
        when :return_empty
          []
        else
          raise Phronomy::ToolError, "#{self.class.name} execution failed: #{e.message}"
        end
      end

      # Instance method for requires_approval? (convenience accessor).
      def requires_approval?
        self.class.requires_approval
      end

      private

      # Validates args against declared parameter types and enum constraints.
      # When on_schema_error is :coerce, attempts type coercion first.
      #
      # @param args [Hash] raw args passed to #call (string or symbol keys)
      # @return [Array(Hash, String|nil)] [possibly_coerced_args, error_message_or_nil]
      def validate_and_coerce(args)
        return [args, nil] if self.class.parameters.empty?

        normalized = (args || {}).transform_keys(&:to_sym)
        coerce_mode = self.class.on_schema_error == :coerce
        result = {}

        self.class.parameters.each do |name, param|
          value = normalized[name]
          next if value.nil? && !param.required

          if coerce_mode
            coerced, error = coerce_value(value, param.type)
            return [nil, error] if error && !coerce_mode
            return [nil, error] if error
            value = coerced
          else
            error = type_error(value, param.type)
            return [nil, error] if error
          end

          enum_vals = self.class.param_enums[name]
          if enum_vals && !enum_vals.map(&:to_s).include?(value.to_s)
            return [nil, "parameter '#{name}' must be one of: #{enum_vals.join(", ")} (got: #{value.inspect})"]
          end

          result[name] = value
        end

        # Merge in any extra keys not covered by declared parameters (pass-through).
        extra = normalized.reject { |k, _| self.class.parameters.key?(k) }
        [result.merge(extra), nil]
      end

      # Returns a type-error message string if +value+ does not match +declared_type+,
      # or nil if the value is acceptable.
      #
      # @param value         [Object]
      # @param declared_type [Symbol, String]  e.g. :string, :integer, :number, :boolean, :array, :object
      def type_error(value, declared_type)
        return nil if value.nil?

        ok = case declared_type.to_sym
        when :string then value.is_a?(String)
        when :integer then value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A-?\d+\z/))
        when :number, :float then value.is_a?(Numeric) || (value.is_a?(String) && value.match?(/\A-?\d+(\.\d+)?\z/))
        when :boolean then [true, false, "true", "false"].include?(value)
        when :array then value.is_a?(Array)
        when :object then value.is_a?(Hash)
        else true # unknown types pass through
        end

        if ok
          nil
        else
          "parameter '#{value.respond_to?(:keys) ? "(object)" : value.inspect}' expected type #{declared_type}"
        end
      end

      # Attempts to coerce +value+ to +declared_type+.
      # Returns [coerced_value, nil] on success, [nil, error_message] on failure.
      def coerce_value(value, declared_type)
        return [value, nil] if value.nil?

        case declared_type.to_sym
        when :string
          [value.to_s, nil]
        when :integer
          coerced = Integer(value)
          [coerced, nil]
        when :number, :float
          coerced = Float(value)
          [coerced, nil]
        when :boolean
          case value.to_s.downcase
          when "true" then [true, nil]
          when "false" then [false, nil]
          else [nil, "parameter cannot be coerced to boolean: #{value.inspect}"]
          end
        else
          # Arrays, objects, unknown types: pass through as-is
          [value, nil]
        end
      rescue ArgumentError, TypeError
        [nil, "parameter cannot be coerced to #{declared_type}: #{value.inspect}"]
      end
    end
  end
end
