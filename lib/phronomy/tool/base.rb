# frozen_string_literal: true

module Phronomy
  module Tool
    # Base class extending RubyLLM::Tool with Phronomy-specific DSL.
    #
    # Additional DSL over RubyLLM::Tool:
    #   - tool_name    : explicit function name exposed to the LLM (overrides auto-conversion)
    #   - scope        : access-scope metadata (:read_only, :write, etc.)
    #   - on_error     : error-handling policy (:raise or :return_empty)
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

      # Overrides RubyLLM::Tool#call to apply the on_error policy and wrap errors as ToolError.
      def call(args)
        super
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
    end
  end
end
