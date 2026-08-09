# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Capability
        # Base class extending RubyLLM::Tool with Phronomy-specific DSL.
        class Base < RubyLLM::Tool
          class << self
            # @api public
            def tool_name(value = nil)
              if value.nil?
                return @tool_name if instance_variable_defined?(:@tool_name)
                return superclass.tool_name if superclass.respond_to?(:tool_name)

                return nil
              end

              @tool_name = value.to_s
            end

            # RubyLLM stores Tool descriptions in a class-instance variable.
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
            alias desc description

            # RubyLLM stores declared parameters in a class-instance variable.
            # Copy the parent's registry on first access so child classes inherit
            # existing parameters while remaining free to add their own.
            # @api public
            def parameters
              return @parameters if instance_variable_defined?(:@parameters)

              parent = superclass.respond_to?(:parameters) ? superclass.parameters : {}
              @parameters = parent.dup
            end

            # RubyLLM stores an explicit .params schema definition in a
            # class-instance variable. Readers must fall back to the parent.
            # @api public
            def params_schema_definition
              return @params_schema_definition if instance_variable_defined?(:@params_schema_definition)
              return superclass.params_schema_definition if superclass.respond_to?(:params_schema_definition)

              nil
            end

            # RubyLLM provider params are also class-instance state. Copy them on
            # first access to preserve inheritance without sharing the top-level
            # mutable Hash between parent and child.
            # @api public
            def provider_params
              return @provider_params if instance_variable_defined?(:@provider_params)

              parent = superclass.respond_to?(:provider_params) ? superclass.provider_params : {}
              @provider_params = duplicate_configuration(parent)
            end

            # @api public
            def param(name, enum: nil, properties: nil, **options)
              super(name, **options)
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

            # @api public
            def execution_mode(value = nil)
              if value.nil?
                return @execution_mode if instance_variable_defined?(:@execution_mode)
                return superclass.execution_mode if superclass.respond_to?(:execution_mode)

                return :blocking_io
              end

              valid = %i[cooperative blocking_io cpu_bound external_process]
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
                return @requires_approval if instance_variable_defined?(:@requires_approval)
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
            self.class.tool_name || super
          end

          def params_schema
            schema = super
            return schema if schema.nil?

            properties = schema.dig("properties") || schema.dig(:properties)
            return schema unless properties

            self.class.param_enums.each do |param_name, values|
              key = properties.key?(param_name.to_s) ? param_name.to_s : param_name.to_sym
              next unless properties[key]

              param_type = properties[key]["type"]
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
            end

            self.class.param_schemas.each do |param_name, nested|
              key = properties.key?(param_name.to_s) ? param_name.to_s : param_name.to_sym
              next unless properties[key]
              properties[key]["properties"] = nested_schema_to_json_schema(nested)
            end

            schema
          end

          # @api public
          def call(args, cancellation_token: nil)
            cancellation_token&.raise_if_cancelled!
            validated_args, schema_error = validate_and_coerce(args)
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
            result = super(validated_args)
            truncate_result_if_needed(result)
          rescue Phronomy::ToolError, Phronomy::CancellationError
            raise
          rescue => error
            if self.class.on_error == :suppress
              msg = "[Phronomy] Tool #{self.class.name} suppressed error: " \
                "#{error.class}: #{error.message}"
              if Phronomy.configuration.logger
                Phronomy.configuration.logger.warn(msg)
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
          def call_async(args, cancellation_token: nil, config: {})
            Phronomy::Agent::ToolExecutor.call_async(
              tool: self,
              args: args,
              cancellation_token: cancellation_token,
              config: config
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
            max = self.class.max_result_size || Phronomy.configuration.tool_result_max_size
            return result unless max && result.respond_to?(:length) && result.length > max

            msg = "[Phronomy] Tool #{self.class.name} result truncated " \
              "(#{result.length} chars > #{max} limit)"
            if Phronomy.configuration.logger
              Phronomy.configuration.logger.warn(msg)
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

          def validate_and_coerce(args)
            return [args, nil] if self.class.parameters.empty?

            normalized = (args || {}).transform_keys(&:to_sym)
            coerce_mode = self.class.on_schema_error == :coerce
            result = {}

            self.class.parameters.each do |name, param|
              value = normalized[name]
              if value.nil?
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

              if param.type.to_sym == :object
                nested_schema = self.class.param_schemas[name]
                if nested_schema
                  error = validate_nested_object(value, nested_schema, name.to_s)
                  return [nil, error] if error
                end
              end

              enum_vals = self.class.param_enums[name]
              if enum_vals && !enum_vals.map(&:to_s).include?(value.to_s)
                return [nil,
                  "parameter '#{name}' must be one of: #{enum_vals.join(", ")} " \
                  "(got: #{value.inspect})"]
              end

              result[name] = value
            end

            extra = normalized.keys - self.class.parameters.keys
            unless extra.empty?
              return [nil, "unknown parameter(s): #{extra.inspect}"]
            end

            [result, nil]
          end

          def nested_schema_to_json_schema(nested)
            nested.each_with_object({}) do |(prop_name, spec), result|
              entry = {"type" => spec[:type].to_s}
              entry["description"] = spec[:desc] if spec[:desc]
              entry["enum"] = spec[:enum] if spec[:enum]
              if spec[:properties]
                entry["properties"] = nested_schema_to_json_schema(spec[:properties])
              end
              result[prop_name.to_s] = entry
            end
          end

          def validate_nested_object(value, properties, path)
            return "field '#{path}' must be an object (Hash)" unless value.is_a?(Hash)

            normalized = value.transform_keys(&:to_sym)
            extra = normalized.keys - properties.keys
            unless extra.empty?
              return "nested field '#{path}' contains undeclared key(s): #{extra.inspect}"
            end

            properties.each do |name, spec|
              field_path = "#{path}.#{name}"
              field_value = normalized[name]

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

          def type_error(value, declared_type)
            return nil if value.nil?

            ok = case declared_type.to_sym
            when :string then value.is_a?(String)
            when :integer then value.is_a?(Integer)
            when :number, :float then value.is_a?(Numeric)
            when :boolean then [true, false].include?(value)
            when :array then value.is_a?(Array)
            when :object then value.is_a?(Hash)
            else true
            end

            return nil if ok

            shown = value.respond_to?(:keys) ? "(object)" : value.inspect
            "parameter '#{shown}' expected type #{declared_type}"
          end

          def coerce_value(value, declared_type)
            return [value, nil] if value.nil?

            case declared_type.to_sym
            when :string
              [value.to_s, nil]
            when :integer
              [Integer(value), nil]
            when :number, :float
              [Float(value), nil]
            when :boolean
              case value.to_s.downcase
              when "true" then [true, nil]
              when "false" then [false, nil]
              else [nil, "parameter cannot be coerced to boolean: #{value.inspect}"]
              end
            else
              [value, nil]
            end
          rescue ArgumentError, TypeError
            [nil, "parameter cannot be coerced to #{declared_type}: #{value.inspect}"]
          end
        end
      end
    end
  end
end
