# frozen_string_literal: true

require_relative "../execution/concurrency/worker_input_restricted"
require_relative "../execution/cancellation_error"
require_relative "../configuration/runtime_settings"
require_relative "tool_error"
require_relative "schema"

module Phronomy
  module Tool
    # Owns Tool declarations, argument validation and the execution template.
    class Base
      include Phronomy::Concurrency::WorkerInputRestricted

      Parameter = Data.define(:name, :type, :description, :required)

      class << self
        # @api public
        def parameter(name, type: :string, description: nil, required: true)
          declared_parameters[name.to_sym] = Parameter.new(name: name.to_sym,
            type: type, description: description, required: required)
        end

        # @api public
        def tool_name(value = nil)
          if value.nil?
            return @tool_name if instance_variable_defined?(:@tool_name)
            ascii = name.to_s.unicode_normalize(:nfkd).encode("ASCII", replace: "").gsub(/[^a-zA-Z0-9_-]/, "-")
            return ascii.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.delete_suffix("_tool")
          end

          @tool_name = value.to_s
        end

        # Tool descriptions inherit through application and decorator classes.
        # Preserve normal class inheritance semantics so Phronomy's anonymous
        # decorator subclasses do not lose their parent's description.
        # @api public
        def description(text = nil)
          unless text
            return @description if instance_variable_defined?(:@description)
            return superclass.description if superclass.respond_to?(:description)

            return nil
          end

          @description = text
        end
        alias_method :desc, :description

        # Phronomy declarations inherit through anonymous Tool decorators.
        # The Tool contract owns schema construction and validation.
        # @api public
        def declared_parameters
          return @declared_parameters if instance_variable_defined?(:@declared_parameters)

          @declared_parameters = superclass.respond_to?(:declared_parameters) ? superclass.declared_parameters.dup : {}
        end

        # Preserve the parameter reader and accept an explicit schema or schema DSL.
        # @api public
        def parameters(schema = :__phronomy_read__, &block)
          return declared_parameters if schema == :__phronomy_read__ && !block

          @parameters_schema_definition = Schema.new((schema == :__phronomy_read__) ? nil : schema, &block)
          self
        end

        # @api public
        def parameters_schema_definition
          return @parameters_schema_definition if instance_variable_defined?(:@parameters_schema_definition)

          superclass.parameters_schema_definition if superclass.respond_to?(:parameters_schema_definition)
        end

        # @api public
        def params_schema_definition
          parameters_schema_definition
        end

        # @api public
        def params(schema = nil, &block)
          parameters(schema, &block)
        end

        # @api public
        def provider_options(options = :__phronomy_read__)
          unless options == :__phronomy_read__
            raise ArgumentError, "provider_options must be a Hash" unless options.is_a?(Hash)
            @provider_options = duplicate_configuration(options)
            return self
          end
          return @provider_options if instance_variable_defined?(:@provider_options)

          @provider_options = superclass.respond_to?(:provider_options) ? duplicate_configuration(superclass.provider_options) : {}
        end

        # @api public
        def provider_params
          provider_options
        end

        # @api public
        def with_params(**options)
          provider_options(options)
        end

        # @api public
        def param(name, enum: nil, properties: nil, desc: nil, **options)
          options[:description] = desc if desc
          parameter(name, **options)
          param_enums[name] = duplicate_configuration(enum) if enum
          param_schemas[name] = normalize_nested_schema(properties) if properties
        end

        # @api public
        def param_enums
          return @param_enums if instance_variable_defined?(:@param_enums)

          parent = superclass.respond_to?(:param_enums) ? superclass.param_enums : {}
          @param_enums = duplicate_configuration(parent)
        end

        # @api public
        def param_schemas
          return @param_schemas if instance_variable_defined?(:@param_schemas)

          parent = superclass.respond_to?(:param_schemas) ? superclass.param_schemas : {}
          @param_schemas = duplicate_configuration(parent)
        end

        private

        def duplicate_configuration(value)
          case value
          when Hash
            value.to_h do |key, child|
              [key, duplicate_configuration(child)]
            end
          when Array
            value.map { |child| duplicate_configuration(child) }
          else
            value
          end
        end

        def normalize_nested_schema(props)
          props.transform_keys(&:to_sym).transform_values do |spec|
            normalized = spec.transform_keys(&:to_sym)
            normalized[:type] ||= :string
            if normalized[:properties]
              normalized[:properties] = normalize_nested_schema(normalized[:properties])
            end
            normalized
          end
        end

        public

        # Declares whether Tool work is safe to run cooperatively on the EventLoop
        # or must be offloaded to a bounded worker pool.
        #
        # Phronomy does not classify the reason for offloading. Blocking I/O,
        # CPU-bound synchronous work, and other long synchronous calls all use
        # +:offloaded+. The application owns that workload classification.
        # @api public
        def execution_mode(value = nil)
          if value.nil?
            return @execution_mode if instance_variable_defined?(:@execution_mode)
            return superclass.execution_mode if superclass.respond_to?(:execution_mode)

            return :offloaded
          end

          valid = %i[cooperative offloaded]
          unless valid.include?(value)
            raise ArgumentError,
              "execution_mode must be one of #{valid.inspect}, got #{value.inspect}"
          end
          @execution_mode = value
        end

        # Configures execution-error handling. Supported values are :raise
        # and :suppress only.
        # @api public
        def on_error(behavior = nil)
          if behavior.nil?
            return @on_error if instance_variable_defined?(:@on_error)
            return superclass.on_error if superclass.respond_to?(:on_error)

            return :raise
          end

          valid = %i[raise suppress]
          unless valid.include?(behavior)
            raise ArgumentError,
              "on_error must be one of #{valid.inspect}, got #{behavior.inspect}"
          end
          @on_error = behavior
        end

        # @api public
        def on_schema_error(behavior = nil)
          if behavior.nil?
            return @on_schema_error if instance_variable_defined?(:@on_schema_error)
            return superclass.on_schema_error if superclass.respond_to?(:on_schema_error)

            return :return_error
          end

          @on_schema_error = behavior
        end

        # @api public
        def requires_approval(value = :__unset__, &block)
          if block
            unless value == :__unset__
              raise ArgumentError, "pass either a value or a block to requires_approval"
            end
            @requires_approval = block
          elsif value == :__unset__
            return @requires_approval unless @requires_approval.nil?
            return superclass.requires_approval if superclass.respond_to?(:requires_approval)

            false
          else
            unless value == true || value == false || value.respond_to?(:call)
              raise ArgumentError, "requires_approval must be true, false, or callable"
            end
            @requires_approval = value
          end
        end

        # @api public
        def approval_facts(&block)
          if block
            @approval_facts = block
          elsif instance_variable_defined?(:@approval_facts)
            @approval_facts
          elsif superclass.respond_to?(:approval_facts)
            superclass.approval_facts
          end
        end

        # @api public
        def redact_params(*names)
          if names.empty?
            parent = superclass.respond_to?(:redact_params) ? superclass.redact_params : []
            ((@redacted_params || []) + parent).uniq
          else
            @redacted_params = ((@redacted_params || []) + names.map(&:to_sym)).uniq
          end
        end

        # @api public
        def max_result_size(value = :__unset__)
          if value == :__unset__
            return @max_result_size if instance_variable_defined?(:@max_result_size)
            return superclass.max_result_size if superclass.respond_to?(:max_result_size)

            return nil
          end

          @max_result_size = value
        end
      end

      def name
        self.class.tool_name
      end

      def description
        self.class.description
      end

      def provider_options
        self.class.provider_options
      end

      def parameters_schema
        definition = self.class.parameters_schema_definition
        return definition.json_schema if definition

        declarations = self.class.declared_parameters
        if declarations.empty?
          declarations = method(:execute).parameters.filter_map do |kind, name|
            next unless %i[key keyreq].include?(kind)
            next if %i[cancellation_token tool_call].include?(name)
            [name, Parameter.new(name: name, type: :string, description: nil, required: kind == :keyreq)]
          end.to_h
        end
        properties = declarations.to_h do |name, parameter|
          type = parameter.type.to_s
          type = "number" if %w[float double].include?(type)
          type = "integer" if type == "int"
          value = {"type" => type, "description" => parameter.description}.compact
          # An unqualified array declaration permits any JSON item. Explicit
          # item constraints belong to an explicit schema.
          value["items"] = {} if type == "array"
          value["type"] = [type, "null"] unless parameter.required
          [name.to_s, value]
        end
        schema = {"type" => "object", "properties" => properties,
                  "required" => declarations.select { |_, parameter| parameter.required }.keys.map(&:to_s),
                  "additionalProperties" => false}

        properties = schema.dig("properties") || schema.dig(:properties)
        return schema unless properties

        self.class.param_enums.each do |param_name, values|
          key = properties.key?(param_name.to_s) ? param_name.to_s : param_name.to_sym
          next unless properties[key]

          param_type = Array(properties[key]["type"]).find { |type| type != "null" }
          properties[key]["enum"] = values.map do |value|
            case param_type
            when "integer"
              value.is_a?(Integer) ? value : Integer(value.to_s)
            when "number"
              value.is_a?(Numeric) ? value : Float(value.to_s)
            when "boolean"
              unless value == true || value == false
                raise ArgumentError,
                  "boolean enum values must be true or false (got: #{value.inspect})"
              end
              value
            else
              value.to_s
            end
          end
          properties[key]["enum"] << nil unless declarations.fetch(param_name.to_sym).required
        end

        self.class.param_schemas.each do |param_name, nested|
          key = properties.key?(param_name.to_s) ? param_name.to_s : param_name.to_sym
          next unless properties[key]
          properties[key]["properties"] = nested_schema_to_json_schema(nested)
          properties[key]["required"] = nested.select { |_, spec| spec[:required] }.keys.map(&:to_s)
          properties[key]["additionalProperties"] = false
        end

        schema
      end

      # Phronomy retains these readers as part of its Tool contract.
      # @api public
      def params_schema
        parameters_schema
      end

      # @api public
      def provider_params
        provider_options
      end

      # @api public
      def parameters
        self.class.declared_parameters
      end

      # Validate/coerce without executing, so approval and execution share inputs.
      # @api public
      def validate_arguments(args)
        schema = parameters_schema
        if !@validation_schema || @validation_schema.json_schema != schema
          @validation_schema = Schema.new(schema)
        end
        values, error = @validation_schema.validate(args || {}, coerce: self.class.on_schema_error == :coerce)
        if values && !self.class.parameters_schema_definition
          # Legacy optional param nil means omission, preserving Ruby defaults.
          self.class.declared_parameters.each do |name, parameter|
            values.delete(name) if !parameter.required && values[name].nil?
          end
        end
        [values, error]
      end

      # @api public
      def call(args, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        validated_args, schema_error = validate_arguments(args)
        if schema_error
          case self.class.on_schema_error
          when :raise
            raise Phronomy::ToolError,
              "#{self.class.name} schema error: #{schema_error}"
          else
            return "Schema validation failed: #{schema_error}"
          end
        end

        if cancellation_token && execute_accepts_cancellation_token?
          validated_args = validated_args.merge(cancellation_token: cancellation_token)
        end
        result = execute(**(validated_args || {}).transform_keys(&:to_sym))
        truncate_result_if_needed(result)
      rescue Phronomy::ToolError, Phronomy::CancellationError
        raise
      rescue => error
        if self.class.on_error == :suppress
          msg = "[Phronomy] Tool #{self.class.name} suppressed error: " \
            "#{error.class}: #{error.message}"
          if Phronomy::RuntimeSettings.current.logger
            Phronomy::RuntimeSettings.current.logger.warn(msg)
          else
            warn msg
          end
          "Tool error suppressed: #{error.message}"
        else
          raise Phronomy::ToolError,
            "#{self.class.name} execution failed: #{error.message}"
        end
      end

      # @api public
      def call_async(
        args,
        cancellation_token: nil,
        config: {}
      )
        Phronomy::Tool::ToolExecutor.call_async(
          tool: self,
          args: args,
          cancellation_token: cancellation_token,
          config: config,
          synchronous_call: Operation.synchronous_delegate(self)
        )
      end

      def requires_approval
        self.class.requires_approval
      end

      def requires_approval?
        self.class.requires_approval
      end

      # @api public
      def tool_origin
        :local
      end

      # @api public
      def approval_metadata
        {}
      end

      # @api public
      def execute(**_args)
        raise NotImplementedError, "#{self.class}#execute is not implemented"
      end

      private

      def execute_accepts_cancellation_token?
        method(:execute).parameters.any? do |type, name|
          name == :cancellation_token && %i[key keyreq].include?(type)
        end
      end

      def truncate_result_if_needed(result)
        max = self.class.max_result_size || Phronomy::RuntimeSettings.current.tool_result_max_size
        return result unless max && result.respond_to?(:length) && result.length > max

        msg = "[Phronomy] Tool #{self.class.name} result truncated " \
          "(#{result.length} chars > #{max} limit)"
        if Phronomy::RuntimeSettings.current.logger
          Phronomy::RuntimeSettings.current.logger.warn(msg)
        else
          warn msg
        end
        "#{result[0, max]}...[truncated]"
      end

      def redacted_args(args)
        redacted = self.class.redact_params
        return args if redacted.empty?

        args.each_with_object({}) do |(key, value), result|
          result[key] = redacted.include?(key.to_sym) ? "[REDACTED]" : value
        end
      end

      def nested_schema_to_json_schema(nested)
        nested.each_with_object({}) do |(prop_name, spec), result|
          type = spec[:type].to_s
          type = "number" if %w[float double].include?(type)
          type = "integer" if type == "int"
          entry = {"type" => spec[:required] ? type : [type, "null"]}
          entry["description"] = spec[:desc] if spec[:desc]
          entry["enum"] = spec[:required] ? spec[:enum] : (spec[:enum] + [nil]).uniq if spec[:enum]
          if spec[:properties]
            entry["properties"] = nested_schema_to_json_schema(spec[:properties])
            entry["required"] = spec[:properties].select { |_, child| child[:required] }.keys.map(&:to_s)
            entry["additionalProperties"] = false
          end
          result[prop_name.to_s] = entry
        end
      end
    end
  end
end
