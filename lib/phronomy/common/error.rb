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
      diagnostic
    end
  end
end
