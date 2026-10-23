# frozen_string_literal: true

require_relative "message"

module Phronomy
  module LLMAdapter
    # Immutable input for one model turn, including inert Tool definitions.
    # @api public
    class Request
      attr_reader :model_config, :system, :messages, :tools, :message, :response_schema

      # @api public
      def initialize(model_config: {}, system: nil, messages: [], tools: [], message: nil, response_schema: nil)
        if !(model_config.is_a?(Hash) && (system.nil? || system.is_a?(String)) && (message.nil? || message.is_a?(String)))
          raise ArgumentError, "invalid LLM request configuration or text"
        end
        unless messages.is_a?(Array) && messages.all? { |item| item.is_a?(Message) }
          raise ArgumentError, "LLM request messages must be Message values"
        end
        unless tools.is_a?(Array) && tools.all? { |tool| tool.is_a?(Hash) }
          raise ArgumentError, "LLM request tools must be definition Hashes"
        end
        normalized_tools = tools.map do |definition|
          definition = normalize_keys(definition)
          name = definition["name"]
          unless name.is_a?(String) && !name.empty? && definition["description"].is_a?(String)
            raise ArgumentError, "Tool definition requires name and description"
          end
          if definition.key?("provider_options") && !definition["provider_options"].is_a?(Hash)
            raise ArgumentError, "Tool provider_options must be a Hash"
          end
          Phronomy::Tool::Schema.new(definition.fetch("parameters_schema"))
          Phronomy::Values::Immutable.validate_canonical_json!(definition, label: "Tool definition")
          definition
        end
        names = normalized_tools.map { |tool| tool.fetch("name") }
        raise ArgumentError, "duplicate Tool definition name" unless names.uniq == names
        config = normalize_keys(model_config)
        @response_schema = response_schema.nil? ? nil : Phronomy::Values::Immutable.json(response_schema)
        if @response_schema && !@response_schema.is_a?(Hash)
          raise ArgumentError, "response_schema must be a JSON object or nil"
        end
        reject_schema_options!(config) if @response_schema
        Phronomy::Values::Immutable.validate_canonical_json!(config, label: "LLM model configuration")
        max = config["max_output_tokens"]
        if !max.nil? && (!max.is_a?(Integer) || max <= 0)
          raise ArgumentError, "max_output_tokens must be a positive Integer"
        end
        %w[model provider].each do |key|
          value = config[key]
          if !(value.nil? || (value.is_a?(String) && !value.empty?))
            raise ArgumentError, "#{key} must be a non-empty String or nil"
          end
        end
        %w[assume_model_exists cache_instructions].each do |key|
          raise ArgumentError, "#{key} must be boolean or nil" unless [true, false, nil].include?(config[key])
        end
        temperature = config["temperature"]
        if !(temperature.nil? || (temperature.is_a?(Numeric) && temperature.finite?))
          raise ArgumentError, "temperature must be a finite number or nil"
        end
        @model_config = Phronomy::Values::Immutable.copy(config)
        @system = system&.dup&.freeze
        @message = message&.dup&.freeze
        @messages = messages.dup.freeze
        @tools = Phronomy::Values::Immutable.copy(normalized_tools)
        freeze
      end

      private

      def reject_schema_options!(value)
        return unless value.is_a?(Hash)
        value.each do |key, child|
          if %w[schema output_schema response_schema response_format responseJsonSchema responseSchema].include?(key.to_s)
            raise ArgumentError, "model configuration cannot override response_schema"
          end
          reject_schema_options!(child)
        end
      end

      def normalize_keys(value)
        value.each_with_object({}) do |(key, child), result|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "LLM configuration/definition keys must be Strings or Symbols"
          end
          name = key.to_s
          raise ArgumentError, "duplicate LLM configuration/definition key: #{name}" if result.key?(name)
          result[name] = child
        end
      end
    end
  end
end
