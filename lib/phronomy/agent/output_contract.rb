# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    # Owns the execution's output promise; generic schema interpretation is injected.
    # @api private
    class OutputContract
      FACTORIES = {}
      private_constant :FACTORIES
      attr_reader :schema, :digest

      def self.install_factory(factory)
        FACTORIES.replace(parser: factory).freeze
      end

      def initialize(schema)
        @parser = FACTORIES.fetch(:parser).call(schema)
        @schema = @parser.json_schema
        @digest = Digest::SHA256.hexdigest(JSON.generate(@schema, sort_keys: true)).freeze
        freeze
      end

      def metadata(contents)
        {"output_contract" => {"version" => 1, "schema_ref" => contents.put_text(JSON.generate(schema, sort_keys: true)), "schema_digest" => digest}}
      end

      def self.restore(execution, contents)
        stored = execution.metadata["output_contract"]
        return nil unless stored
        raise ArgumentError, "unsupported Agent output contract version" unless stored.fetch("version") == 1
        contract = new(contents.fetch_json(stored.fetch("schema_ref")))
        unless contract.digest == stored.fetch("schema_digest")
          raise Phronomy::ContentStore::IntegrityError, "Agent output schema digest mismatch"
        end
        contract
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
