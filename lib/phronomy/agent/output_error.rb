# frozen_string_literal: true

module Phronomy
  module Agent
    # A declared output contract could not be fulfilled. Tool effects remain facts.
    # @api public
    class OutputError < Phronomy::Error
      CODES = {"invalid_json" => "agent.output_invalid", "schema_mismatch" => "agent.output_invalid",
               "missing_output" => "agent.output_invalid", "model_refusal" => "agent.output_refused",
               "length" => "agent.output_incomplete", "content_filter" => "agent.output_incomplete",
               "unknown_finish_reason" => "agent.output_incomplete"}.freeze
      private_constant :CODES

      # @api public
      attr_reader :execution_id, :schema_digest, :reason, :violations, :raw_output

      # @api public
      def initialize(execution_id:, schema_digest:, reason:, violations: [], raw_output: nil)
        @execution_id = execution_id.to_s.dup.freeze
        @schema_digest = schema_digest.to_s.dup.freeze
        @reason = reason.to_s.dup.freeze
        @violations = Phronomy::Values::Immutable.json(violations)
        @raw_output = Phronomy::Values::Immutable.copy(raw_output)
        super("Agent output contract failed: #{@reason}", code: CODES.fetch(@reason))
      end

      # Owner-defined facts for persistence and composition; no live exception values.
      # @api private
      def diagnostic(include_raw: true)
        value = Phronomy::Error.diagnostic(self).merge("execution_id" => execution_id,
          "schema_digest" => schema_digest, "reason" => reason, "violations" => violations)
        value["raw_output"] = raw_output if include_raw
        Phronomy::Values::Immutable.json(value)
      end

      # @api private
      def self.restore(value)
        error = new(execution_id: value.fetch("execution_id"), schema_digest: value.fetch("schema_digest"),
          reason: value.fetch("reason"), violations: value.fetch("violations"), raw_output: value["raw_output"])
        raise ArgumentError, "invalid Agent output diagnostic code" unless error.code == value.fetch("code")
        if value["cause"]
          begin
            raise error, cause: Phronomy::Error.from_diagnostic(value.fetch("cause"))
          rescue OutputError => restored
            restored.set_backtrace(nil)
            return restored
          end
        end
        error
      end
    end
  end
end
