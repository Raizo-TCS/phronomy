# frozen_string_literal: true

module Phronomy
  module Agent
    # ContentStore-backed durable codec boundary for one Provider input manifest.
    # It is intentionally separate from Persistence::DurableRecord.
    class LLMInputManifest
      VERSION = "0.1"
      CALL_MODES = %i[ask complete].freeze
      SEGMENT_DELIVERIES = %w[ask_argument chat_message].freeze

      Segment = Data.define(
        :position, :category, :role, :content_ref, :delivery,
        :tool_call_id, :metadata
      ) do
        def initialize(**values)
          delivery = values[:delivery]
          if delivery && !SEGMENT_DELIVERIES.include?(delivery.to_s)
            raise ArgumentError, "unknown Segment delivery: #{delivery.inspect}"
          end
          super(**values.merge(metadata: Immutable.copy(values[:metadata] || {})))
          freeze
        end

        def self.from_h(hash)
          source = LLMInputManifest.send(
            :strict_source!,
            hash,
            required: %w[position category content_ref delivery metadata],
            optional: %w[role tool_call_id],
            label: "LLMInputManifest segment"
          )
          label = "LLMInputManifest segment"
          position = LLMInputManifest.send(
            :require_nonnegative_integer_field!,
            source,
            "position",
            label: label
          )
          category = LLMInputManifest.send(
            :require_nonempty_string_field!,
            source,
            "category",
            label: label
          )
          role = LLMInputManifest.send(
            :require_optional_string_field!,
            source,
            "role",
            label: label
          )
          content_ref = LLMInputManifest.send(
            :require_nonempty_string_field!,
            source,
            "content_ref",
            label: label
          )
          delivery = LLMInputManifest.send(
            :require_nonempty_string_field!,
            source,
            "delivery",
            label: label
          )
          unless SEGMENT_DELIVERIES.include?(delivery)
            raise Phronomy::Persistence::SerializationError,
              "LLMInputManifest segment delivery must be one of #{SEGMENT_DELIVERIES.inspect}, got #{delivery.inspect}"
          end
          tool_call_id = LLMInputManifest.send(
            :require_optional_string_field!,
            source,
            "tool_call_id",
            label: label
          )
          metadata = LLMInputManifest.send(
            :require_hash_field!,
            source,
            "metadata",
            label: label
          )

          new(
            position: position,
            category: category.to_sym,
            role: role&.to_sym,
            content_ref: content_ref,
            delivery: delivery.to_sym,
            tool_call_id: tool_call_id,
            metadata: metadata
          )
        rescue Phronomy::Persistence::SerializationError
          raise
        rescue => error
          raise Phronomy::Persistence::SerializationError,
            "invalid LLMInputManifest segment: #{error.class}: #{error.message}"
        end

        def to_h
          {
            "position" => position,
            "category" => category.to_s,
            "role" => role&.to_s,
            "content_ref" => content_ref,
            "delivery" => delivery.to_s,
            "tool_call_id" => tool_call_id,
            "metadata" => metadata
          }.compact
        end
      end

      REQUIRED_KEYS = %w[
        version call_sequence call_mode assembly_policy_version segments
        model_config_ref
      ].freeze
      OPTIONAL_KEYS = %w[
        tool_definitions_ref response_schema_ref ruby_llm_version
        adapter_name adapter_version
      ].freeze

      attr_reader :version, :call_sequence, :call_mode,
        :assembly_policy_version, :segments,
        :model_config_ref, :tool_definitions_ref, :response_schema_ref,
        :ruby_llm_version, :adapter_name, :adapter_version

      def initialize(
        call_sequence:,
        call_mode:,
        segments:,
        model_config_ref:,
        tool_definitions_ref: nil,
        response_schema_ref: nil,
        assembly_policy_version: 1,
        ruby_llm_version: nil,
        adapter_name: nil,
        adapter_version: nil,
        version: VERSION
      )
        @version = String(version).freeze
        @call_sequence = Integer(call_sequence)
        @call_mode = call_mode.to_sym
        @assembly_policy_version = Integer(assembly_policy_version)
        @segments = Array(segments).sort_by(&:position).freeze
        @model_config_ref = model_config_ref.to_s.freeze
        @tool_definitions_ref = tool_definitions_ref&.to_s&.freeze
        @response_schema_ref = response_schema_ref&.to_s&.freeze
        @ruby_llm_version = ruby_llm_version&.to_s&.freeze
        @adapter_name = adapter_name&.to_s&.freeze
        @adapter_version = adapter_version&.to_s&.freeze
        validate!
        freeze
      end

      # Current-format-only durable decoder. Historical format conversion is an
      # explicit migration operation and is never attempted here. Unlike the
      # Ruby construction API, this decoder never coerces durable field types.
      def self.from_h(hash)
        source = strict_source!(
          hash,
          required: REQUIRED_KEYS,
          optional: OPTIONAL_KEYS,
          label: "LLMInputManifest"
        )
        label = "LLMInputManifest"
        version = source.fetch("version")
        unless version.is_a?(String) && version == VERSION
          raise Phronomy::Persistence::SerializationError,
            "unsupported LLMInputManifest version: #{version.inspect}; " \
            "current version is #{VERSION.inspect}"
        end

        call_sequence = require_positive_integer_field!(
          source,
          "call_sequence",
          label: label
        )
        call_mode = require_enum_string_field!(
          source,
          "call_mode",
          CALL_MODES.map(&:to_s),
          label: label
        )
        assembly_policy_version = require_integer_field!(
          source,
          "assembly_policy_version",
          label: label
        )
        segments = require_array_field!(source, "segments", label: label)
          .map { |segment| Segment.from_h(segment) }
        model_config_ref = require_nonempty_string_field!(
          source,
          "model_config_ref",
          label: label
        )
        tool_definitions_ref = require_optional_string_field!(
          source,
          "tool_definitions_ref",
          label: label
        )
        response_schema_ref = require_optional_string_field!(
          source,
          "response_schema_ref",
          label: label
        )
        ruby_llm_version = require_optional_string_field!(
          source,
          "ruby_llm_version",
          label: label
        )
        adapter_name = require_optional_string_field!(
          source,
          "adapter_name",
          label: label
        )
        adapter_version = require_optional_string_field!(
          source,
          "adapter_version",
          label: label
        )

        new(
          version: version,
          call_sequence: call_sequence,
          call_mode: call_mode.to_sym,
          assembly_policy_version: assembly_policy_version,
          segments: segments,
          model_config_ref: model_config_ref,
          tool_definitions_ref: tool_definitions_ref,
          response_schema_ref: response_schema_ref,
          ruby_llm_version: ruby_llm_version,
          adapter_name: adapter_name,
          adapter_version: adapter_version
        )
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        raise Phronomy::Persistence::SerializationError,
          "invalid LLMInputManifest: #{error.class}: #{error.message}"
      end

      def referenced_content_refs
        ([model_config_ref, tool_definitions_ref, response_schema_ref] +
          segments.map(&:content_ref)).compact.uniq.freeze
      end

      def to_h
        {
          "version" => version,
          "call_sequence" => call_sequence,
          "call_mode" => call_mode.to_s,
          "assembly_policy_version" => assembly_policy_version,
          "segments" => segments.map(&:to_h),
          "model_config_ref" => model_config_ref,
          "tool_definitions_ref" => tool_definitions_ref,
          "response_schema_ref" => response_schema_ref,
          "ruby_llm_version" => ruby_llm_version,
          "adapter_name" => adapter_name,
          "adapter_version" => adapter_version
        }.compact
      end

      class << self
        private

        def strict_source!(hash, required:, optional:, label:)
          unless hash.is_a?(Hash)
            raise Phronomy::Persistence::SerializationError,
              "#{label} must be a Hash"
          end
          unless hash.keys.all? { |key| key.is_a?(String) }
            raise Phronomy::Persistence::SerializationError,
              "#{label} keys must all be String"
          end

          actual = hash.keys
          missing = required - actual
          unknown = actual - (required + optional)
          unless missing.empty? && unknown.empty?
            details = []
            details << "missing=#{missing.inspect}" unless missing.empty?
            details << "unknown=#{unknown.inspect}" unless unknown.empty?
            raise Phronomy::Persistence::SerializationError,
              "#{label} schema mismatch (#{details.join(", ")})"
          end
          Phronomy::CanonicalJSON.dump(hash)
          hash
        rescue ArgumentError => error
          raise Phronomy::Persistence::SerializationError,
            "#{label} is not canonical JSON compatible: #{error.message}"
        end

        def require_integer_field!(hash, key, label:)
          value = hash.fetch(key)
          return value if value.is_a?(Integer)

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be an Integer"
        end

        def require_positive_integer_field!(hash, key, label:)
          value = hash.fetch(key)
          return value if value.is_a?(Integer) && value.positive?

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be a positive Integer"
        end

        def require_nonnegative_integer_field!(hash, key, label:)
          value = hash.fetch(key)
          return value if value.is_a?(Integer) && value >= 0

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be a non-negative Integer"
        end

        def require_nonempty_string_field!(hash, key, label:)
          value = hash.fetch(key)
          return value if value.is_a?(String) && !value.empty?

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be a non-empty String"
        end

        def require_optional_string_field!(hash, key, label:)
          value = hash[key]
          return value if value.nil? || value.is_a?(String)

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be a String or nil"
        end

        def require_enum_string_field!(hash, key, allowed, label:)
          value = hash.fetch(key)
          return value if value.is_a?(String) && allowed.include?(value)

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be one of #{allowed.inspect}"
        end

        def require_array_field!(hash, key, label:)
          value = hash.fetch(key)
          return value if value.is_a?(Array)

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be an Array"
        end

        def require_hash_field!(hash, key, label:)
          value = hash.fetch(key)
          return value if value.is_a?(Hash)

          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be a Hash"
        end
      end

      private

      def validate!
        unless version == VERSION
          raise Phronomy::ConfigurationError,
            "unsupported LLMInputManifest version: #{version.inspect}; " \
            "current version is #{VERSION.inspect}"
        end
        raise ArgumentError, "invalid manifest call mode: #{call_mode.inspect}" unless CALL_MODES.include?(call_mode)
        raise ArgumentError, "call_sequence must be positive" unless call_sequence.positive?
        expected = (0...segments.length).to_a
        actual = segments.map(&:position)
        raise ArgumentError, "manifest positions must be contiguous: #{actual.inspect}" unless actual == expected

        ask_count = segments.count { |segment| segment.delivery == :ask_argument }
        expected_ask_count = (call_mode == :ask) ? 1 : 0
        unless ask_count == expected_ask_count
          raise ArgumentError,
            "#{call_mode} manifest requires #{expected_ask_count} ask_argument segment(s), got #{ask_count}"
        end
      end
    end
  end
end
