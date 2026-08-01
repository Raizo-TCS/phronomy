# frozen_string_literal: true

module Phronomy
  # Raised when an Application stream callback fails and
  # +stream_callback_error_policy+ is +:fail_task+.
  #
  # This error represents delivery failure, not Agent, LLM, Tool, or FSM
  # execution failure. The Agent result is retained in {#result}, and the
  # original Application exception is available through both
  # {#original_error} and Ruby's +#cause+ chain.
  #
  # @api public
  class StreamCallbackError < Error
    # @return [Symbol] stream event type handled by the failing callback
    attr_reader :event_type

    # @return [Hash, nil] successful or suspended Agent result
    attr_reader :result

    # @return [Exception] original Application callback exception
    attr_reader :original_error

    def initialize(event_type:, original_error:, result: nil)
      @event_type = event_type
      @original_error = original_error
      @result = result

      super(
        "Stream callback failed while handling #{event_type.inspect}: " \
        "#{original_error.class}: #{original_error.message}"
      )
      set_backtrace(original_error.backtrace)
    end
  end
end
