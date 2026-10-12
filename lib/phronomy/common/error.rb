# frozen_string_literal: true

module Phronomy
  class Error < StandardError
    # Optional stable reason supplied by the owner of the failed operation.
    # It does not imply retry safety or replace execution status.
    # @api public
    attr_reader :code

    # Existing message-only construction retains StandardError behavior.
    # @api public
    def initialize(message = nil, code: nil)
      raise ArgumentError, "error code must be a String or nil" unless code.nil? || code.is_a?(String)
      @code = code&.dup&.freeze
      super(message)
    end

    # Generic diagnostic transport. No domain-specific interpretation.
    # External exceptions are not extended with this protocol.
    # @api private
    def self.diagnostic(error)
      diagnostic = {"class" => error.class.name, "message" => error.message}
      diagnostic["code"] = error.code if error.is_a?(Phronomy::Error) && error.code
      cause = error.cause
      diagnostic["cause"] = cause_diagnostic(cause, remaining: 3, seen: [error.object_id]) if cause
      diagnostic
    end

    # Restores data, never a saved class name or arbitrary instance attributes.
    # Restored causes are generic errors as well. Old diagnostics remain valid.
    # @api private
    def self.from_diagnostic(value, remaining: 3)
      hash = value.to_h { |key, item| [key.to_s, item] }
      error = Phronomy::Error.new(
        "#{hash.fetch("class", "Error")}: #{hash.fetch("message", "Recovery-resolved failure")}",
        code: hash["code"]
      )
      return error unless remaining.positive? && hash["cause"].is_a?(Hash) && hash["cause"].key?("class")

      cause = from_diagnostic(hash["cause"], remaining: remaining - 1)
      begin
        raise error, cause: cause
      rescue Phronomy::Error => restored
        restored.set_backtrace(nil)
        restored
      end
    end

    def self.cause_diagnostic(error, remaining:, seen:)
      return {"truncated" => true} if remaining.zero? || seen.include?(error.object_id)

      # Bound newly added cause data; retain the existing top-level format.
      fields = {"class" => error.class.name, "message" => error.message}
      fields["code"] = error.code if error.is_a?(Phronomy::Error) && error.code
      diagnostic = fields.to_h do |key, value|
        [key, value.is_a?(String) ? value[0, 2048] : value]
      end
      # Never turn a truncated reason into a different, apparently valid code.
      diagnostic.delete("code") if fields["code"] && fields["code"].length > 2048
      diagnostic["truncated"] = true if diagnostic != fields
      if error.cause
        diagnostic["cause"] = cause_diagnostic(error.cause,
          remaining: remaining - 1, seen: seen + [error.object_id])
      end
      diagnostic
    end
    private_class_method :cause_diagnostic
  end
end
