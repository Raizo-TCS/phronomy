# frozen_string_literal: true

module Phronomy
  module Agent
    module Concerns
      # Translates RubyLLM transport errors into the corresponding Phronomy error
      # classes so that callers can rescue Phronomy-namespaced exceptions rather
      # than coupling themselves to the underlying provider library.
      #
      # Included in {Phronomy::Agent::Base}.
      module ErrorTranslation
        private

        # Re-raises +error+ as the most specific Phronomy error class that
        # corresponds to it.  Non-RubyLLM errors are re-raised unchanged.
        # The original exception is available as +#cause+ on the translated error.
        #
        # Must be called from within an active +rescue+ block so that Ruby
        # automatically sets +#cause+ on the new exception.
        #
        # @param error [Exception]
        # @raise [Phronomy::RateLimitError] for provider HTTP 429
        # @raise [Phronomy::AuthenticationError] for provider HTTP 401 / 403
        # @raise [Phronomy::ContextLengthError] for context window overflow
        # @raise [Phronomy::TransportError] for all other +RubyLLM::Error+ subclasses
        # @raise re-raises +error+ unchanged for non-RubyLLM exceptions
        # @api private
        def translate_and_reraise!(error)
          case error
          when RubyLLM::RateLimitError
            raise Phronomy::RateLimitError, error.message
          when RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError
            raise Phronomy::AuthenticationError, error.message
          when RubyLLM::ContextLengthExceededError
            raise Phronomy::ContextLengthError, error.message
          when RubyLLM::Error
            raise Phronomy::TransportError, error.message
          else
            raise error # preserve original class, message, and backtrace
          end
        end
      end
    end
  end
end
