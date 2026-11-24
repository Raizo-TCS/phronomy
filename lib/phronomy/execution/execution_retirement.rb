# frozen_string_literal: true

module Phronomy
  # Neutral completion-custody message. Accepting this exact message means the
  # receiver retained responsibility before its transport waiter is detached.
  # It does not establish a domain outcome or authorize domain-owner release.
  # @api private
  class ExecutionRetirement
    UNSUPPORTED = Object.new.freeze

    Acceptance = Data.define(:retirement)

    attr_reader :fsm_session_id, :reason, :error

    def initialize(fsm_session_id:, reason:, error: nil)
      @fsm_session_id = fsm_session_id.to_s.dup.freeze
      @reason = reason
      @error = error
      freeze
    end

    def acceptance
      Acceptance.new(retirement: self)
    end

    def accepted_by?(value)
      value.is_a?(Acceptance) && value.retirement.equal?(self)
    end
  end
end
