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

        # Extends RubyLLM::Tool.param with optional +enum:+ and +properties:+ keywords.
        # - +enum:+       restricts allowed values; injected into the JSON Schema.
        # - +properties:+ declares nested fields for :object type params.  Each
        #   entry is a Hash mapping field name (Symbol) to a spec Hash with keys:
        #   :type (Symbol, default :string), :required (Boolean, default false),
        #   and optionally :properties (for further nesting).
        #
        # @param name [Symbol] parameter name
        # @param enum [Array, nil] allowed values
        # @param properties [Hash, nil] nested schema for :object params
        # @param options [Hash] forwarded to RubyLLM::Tool.param
        def param(name, enum: nil, properties: nil, **options)
          super(name, **options)
          param_enums[name] = enum if enum
          param_schemas[name] = normalize_nested_schema(properties) if properties
        end

        # Returns the enum constraints registered via .param.
        # @return [Hash{Symbol => Array}]
        def param_enums
          @param_enums ||= {}
        end

        # Returns nested schema definitions registered via .param(properties: ...).
        # @return [Hash{Symbol => Hash}]
        def param_schemas
          @param_schemas ||= {}
        end

        private

        # Recursively normalises a properties hash so all keys are Symbols and
        # each spec has a :type key.
        def normalize_nested_schema(props)
          props.transform_keys(&:to_sym).transform_values do |spec|
            s = spec.transform_keys(&:to_sym)
            s[:type] ||= :string
            s[:properties] = normalize_nested_schema(s[:properties]) if s[:properties]
            s
          end
        end

        public

        # Sets the access scope for this tool (metadata; enforcement is the responsibility of
        # the Workflow/Guardrail layer).
        # @param value [Symbol] e.g. :read_only, :write, :admin
        def scope(value = nil)
          return @scope if value.nil?

          @scope = value
        end

        # Configures error-handling behavior when +execute+ raises an unexpected error.
        #
        # @param behavior [Symbol]
        #   :raise        (default)  — re-raise as Phronomy::ToolError, stopping the agent.
        #   :suppress                — suppress the error and return a descriptive string so
        #                             the LLM can recover on the next turn.
        #   :return_empty            — *deprecated* alias for +:suppress+; will be removed in a
        #                             future major release.
        def on_error(behavior = nil)
          return @on_error || :raise if behavior.nil?

          if behavior == :return_empty
            msg = "[Phronomy] on_error :return_empty is deprecated; use :suppress instead"
            if Phronomy.configuration.logger
              Phronomy.configuration.logger.warn(msg)
            else
              warn msg
            end
          end
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

        # Registers a retry policy for one or more exception classes.
        #
        # When the tool raises one of the listed exception classes, it will be
        # retried up to +times+ times with the specified wait strategy.
        # Multiple policies can be registered and are evaluated in order.
        #
        # GuardrailError is never retried regardless of this configuration.
        #
        # @param exception_classes [Array<Class>] exception classes to retry on
        # @param times  [Integer] maximum retry attempts (default: 1)
        # @param wait   [Symbol, Numeric] :exponential, :linear, or a fixed Float
        # @param base   [Float]   base wait time in seconds (default: 1.0)
        #
        # @example
        #   retry_on Phronomy::ToolError, times: 3, wait: :exponential, base: 1.0
        #   retry_on Net::ReadTimeout, times: 2, wait: 0.5
        def retry_on(*exception_classes, times: 1, wait: 0, base: 1.0)
          @retry_policies ||= []
          @retry_policies << {exceptions: exception_classes, times: times, wait: wait, base: base}
        end

        # Returns all retry policies registered on this tool class.
        # @return [Array<Hash>]
        def retry_policies
          @retry_policies || []
        end

        # Injectable sleep callable for testing.
        # Defaults to Kernel#sleep.
        # @return [#call]
        def _sleep_proc
          @_sleep_proc || method(:sleep)
        end

        # Overrides the sleep callable used between retries.
        # @param proc [#call]
        attr_writer :_sleep_proc
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
        return schema if schema.nil?

        properties = schema.dig("properties") || schema.dig(:properties)
        return schema unless properties

        # Inject enum values for params declared with enum: [...].
        unless self.class.param_enums.empty?
          enums = self.class.param_enums
          enums.each do |param_name, values|
            key = properties.key?(param_name.to_s) ? param_name.to_s : param_name.to_sym
            next unless properties[key]

            param_type = properties[key]["type"]
            properties[key]["enum"] = values.map do |v|
              case param_type
              when "integer" then v.is_a?(Integer) ? v : Integer(v.to_s)
              when "number" then v.is_a?(Numeric) ? v : Float(v.to_s)
              else v.to_s
              end
            end
          end
        end

        # Inject nested properties for :object params (issue #162).
        # Without this the LLM sees only { "type": "object" } with no field
        # definitions, making it unable to populate nested object params.
        self.class.param_schemas.each do |param_name, nested|
          key = properties.key?(param_name.to_s) ? param_name.to_s : param_name.to_sym
          next unless properties[key]

          properties[key]["properties"] = nested_schema_to_json_schema(nested)
        end

        schema
      end

      # Overrides RubyLLM::Tool#call to apply schema validation, the retry policy,
      # the on_error policy, and wrap errors as ToolError.
      #
      # Execution order:
      #   1. Schema validation (type + enum checks).
      #   2. Inject +cancellation_token:+ into args when +execute+ opts in.
      #   3. Call super(validated_args) inside a retry loop.
      #   4. On persistent failure, apply on_error policy.
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
        ct = Thread.current[:phronomy_cancellation_token]
        validated_args = validated_args.merge(cancellation_token: ct) if ct && execute_accepts_cancellation_token?
        with_tool_retry { super(validated_args) }
      rescue Phronomy::ToolError
        raise
      rescue Phronomy::CancellationError
        raise
      rescue => e
        case self.class.on_error
        when :return_empty, :suppress
          msg = "[Phronomy] Tool #{self.class.name} suppressed error: #{e.class}: #{e.message}"
          if Phronomy.configuration.logger
            Phronomy.configuration.logger.warn(msg)
          else
            warn msg
          end
          "Tool error suppressed: #{e.message}"
        else
          raise Phronomy::ToolError, "#{self.class.name} execution failed: #{e.message}"
        end
      end

      # Instance method accessor — delegates to the class-level flag.
      def requires_approval
        self.class.requires_approval
      end

      # Instance method for requires_approval? (convenience accessor).
      def requires_approval?
        self.class.requires_approval
      end

      # Override this method to implement the tool's logic.
      #
      # The method receives the declared {.param} fields as keyword arguments.
      # The return value is passed back to the LLM as the tool result.
      #
      # @abstract Subclasses must implement this method.
      # @return [String] result string returned to the LLM
      # @example
      #   class WeatherTool < Phronomy::Tool::Base
      #     description "Get current weather"
      #     param :location, type: :string, desc: "City name"
      #
      #     def execute(location:)
      #       WeatherService.fetch(location).to_s
      #     end
      #   end
      def execute(**_args)
        raise NotImplementedError, "#{self.class}#execute is not implemented"
      end

      private

      # Returns true when the #execute method declares a +cancellation_token:+
      # keyword parameter, indicating it opts into cooperative cancellation.
      def execute_accepts_cancellation_token?
        method(:execute).parameters.any? do |type, name|
          name == :cancellation_token && %i[key keyreq].include?(type)
        end
      end

      # Executes the given block inside a retry loop driven by the class-level
      # retry_policies. Each policy matches by exception class; the first matching
      # policy governs the wait and retry count. Raises immediately when no policy
      # covers the exception or when all retries are exhausted.
      def with_tool_retry
        policies = self.class.retry_policies
        return yield if policies.empty?

        attempt = 0
        begin
          yield
        rescue => e
          policy = policies.find { |p| p[:exceptions].any? { |ex| e.is_a?(ex) } }
          if policy && attempt < policy[:times]
            wait = compute_retry_wait(policy[:wait], policy[:base], attempt)
            self.class._sleep_proc.call(wait) if wait > 0
            attempt += 1
            retry
          end
          raise
        end
      end

      # Computes the wait duration for a given strategy, base, and attempt index.
      #
      # @param strategy [Symbol, Numeric] :exponential, :linear, or a fixed Numeric
      # @param base     [Float]           base wait time in seconds
      # @param attempt  [Integer]         zero-based attempt index
      # @return [Float]
      def compute_retry_wait(strategy, base, attempt)
        case strategy
        when :exponential
          (2**attempt) * base
        when :linear
          (attempt + 1) * base
        when Numeric
          strategy.to_f
        else
          base.to_f
        end
      end

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
          if value.nil?
            # Return a descriptive error for missing required params so the LLM
            # can self-correct on the next turn.
            return [nil, "required parameter '#{name}' is missing"] if param.required
            next
          end

          if coerce_mode
            coerced, error = coerce_value(value, param.type)
            return [nil, error] if error
            value = coerced
          else
            error = type_error(value, param.type)
            return [nil, error] if error
          end

          # Recursively validate nested object properties when declared.
          if param.type.to_sym == :object
            nested_schema = self.class.param_schemas[name]
            if nested_schema
              error = validate_nested_object(value, nested_schema, name.to_s)
              return [nil, error] if error
            end
          end

          enum_vals = self.class.param_enums[name]
          if enum_vals && !enum_vals.map(&:to_s).include?(value.to_s)
            return [nil, "parameter '#{name}' must be one of: #{enum_vals.join(", ")} (got: #{value.inspect})"]
          end

          result[name] = value
        end

        # Reject any keys not covered by declared parameters to prevent silent
        # parameter injection (e.g. via prompt injection).
        extra = normalized.keys - self.class.parameters.keys
        unless extra.empty?
          return [nil, "unknown parameter(s): #{extra.inspect}"]
        end

        [result, nil]
      end

      # Converts the internal normalized nested schema (from param_schemas) to
      # a JSON Schema +properties+ hash suitable for inclusion in the LLM tool
      # definition (issue #162).
      #
      # @param nested [Hash{Symbol=>Hash}] normalized schema from param_schemas
      # @return [Hash{String=>Hash}] JSON Schema properties
      def nested_schema_to_json_schema(nested)
        nested.each_with_object({}) do |(prop_name, spec), acc|
          entry = {"type" => spec[:type].to_s}
          entry["description"] = spec[:desc] if spec[:desc]
          entry["enum"] = spec[:enum] if spec[:enum]
          entry["properties"] = nested_schema_to_json_schema(spec[:properties]) if spec[:properties]
          acc[prop_name.to_s] = entry
        end
      end

      # Recursively validates +value+ (a Hash) against a +properties+ schema.
      # Returns an error message string or nil.
      #
      # @param value      [Hash]            the object value to validate
      # @param properties [Hash{Symbol=>Hash}] nested schema from param_schemas
      # @param path       [String]          dot-separated field path for error messages
      def validate_nested_object(value, properties, path)
        return "field '#{path}' must be an object (Hash)" unless value.is_a?(Hash)

        normalized = value.transform_keys(&:to_sym)

        # Reject extra keys not declared in the schema (issue #166).
        extra = normalized.keys - properties.keys
        unless extra.empty?
          return "nested field '#{path}' contains undeclared key(s): #{extra.inspect}"
        end

        properties.each do |fname, spec|
          field_path = "#{path}.#{fname}"
          field_value = normalized[fname]

          if field_value.nil?
            return "nested required field '#{field_path}' is missing" if spec[:required]
            next
          end

          error = type_error(field_value, spec[:type])
          return "nested field '#{field_path}': #{error}" if error

          next unless spec[:type].to_sym == :object && spec[:properties]

          error = validate_nested_object(field_value, spec[:properties], field_path)
          return error if error
        end
        nil
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
        when :integer then value.is_a?(Integer)
        when :number, :float then value.is_a?(Numeric)
        when :boolean then [true, false].include?(value)
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
