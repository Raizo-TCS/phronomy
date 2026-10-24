# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    # Owns the execution's output promise; generic schema interpretation is injected.
    # @api private
    class OutputContract
      FACTORIES = {}
      private_constant :FACTORIES
      attr_reader :schema, :digest, :schema_delivery

      def self.install_factory(factory)
        FACTORIES.replace(parser: factory).freeze
      end

      def initialize(schema, schema_delivery: :native)
        unless %i[native none].include?(schema_delivery)
          raise ArgumentError, "schema_delivery must be :native or :none"
        end
        @schema_delivery = schema_delivery
        @parser = FACTORIES.fetch(:parser).call(schema)
        @schema = @parser.json_schema
        @digest = Digest::SHA256.hexdigest(JSON.generate(@schema, sort_keys: true)).freeze
        freeze
      end

      def metadata(contents)
        {"output_contract" => {"version" => 2, "schema_ref" => contents.put_text(JSON.generate(schema, sort_keys: true)),
                               "schema_digest" => digest, "schema_delivery" => schema_delivery.to_s}}
      end

      def self.restore(execution, contents)
        stored = execution.metadata["output_contract"]
        return nil unless stored
        contract = new(contents.fetch_json(stored.fetch("schema_ref")), schema_delivery: delivery(stored))
        unless contract.digest == stored.fetch("schema_digest")
          raise Phronomy::ContentStore::IntegrityError, "Agent output schema digest mismatch"
        end
        contract
      end

      # The schema stays durable even when the provider receives no schema.
      def self.response_schema_ref(metadata)
        stored = metadata["output_contract"]
        stored.fetch("schema_ref") if stored && delivery(stored) == :native
      end

      def self.delivery(stored)
        case stored.fetch("version")
        when 1 then :native
        when 2
          value = stored.fetch("schema_delivery")
          unless %w[native none].include?(value)
            raise ArgumentError, "unsupported Agent schema delivery"
          end
          value.to_sym
        else
          raise ArgumentError, "unsupported Agent output contract version"
        end
      end

      # Agent owns the final-output contract, including bypass prevention when
      # no native schema is sent. Provider configuration cannot replace it.
      def self.validate_model_config!(value)
        case value
        when Hash
          value.each do |key, child|
            if %w[schema schema_delivery output_schema response_schema response_format responseJsonSchema responseSchema
              text.format output_config.format].include?(key.to_s) ||
                (%w[text output_config].include?(key.to_s) && child.is_a?(Hash) && child.keys.any? { |name| name.to_s == "format" })
              raise ArgumentError, "model configuration cannot override the Agent output contract"
            end
            validate_model_config!(child)
          end
        when Array
          value.each { |child| validate_model_config!(child) }
        end
      end

      def validate(output, response:, execution_id:)
        raw = response&.content
        reason = if response&.refusal || response&.finish_reason == :refusal
          "model_refusal"
        elsif !response || !%i[stop].include?(response.finish_reason) || !response.tool_calls.empty?
          %i[length content_filter].include?(response&.finish_reason) ? response.finish_reason.to_s : "unknown_finish_reason"
        elsif output.nil? || raw.nil?
          "missing_output"
        end
        if reason
          raise OutputError.new(execution_id: execution_id, schema_digest: digest, reason: reason, raw_output: raw)
        end
        @parser.parse(output)
      rescue Phronomy::ParseError => error
        reason = case error.code
        when "output_parser.invalid_json" then "invalid_json"
        when "output_parser.schema_mismatch" then "schema_mismatch"
        else raise
        end
        raise OutputError.new(execution_id: execution_id, schema_digest: digest, reason: reason,
          violations: error.details, raw_output: raw), cause: error
      end
    end
  end
end
