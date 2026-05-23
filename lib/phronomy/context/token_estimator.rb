# frozen_string_literal: true

module Phronomy
  module Context
    # Central, stateless token estimation utility.
    #
    # All token counting in the framework passes through this module so that the
    # approximation logic lives in one place and can be upgraded without touching
    # any other class.
    #
    # Default approximation: ceil(char_count / 4).
    # This heuristic is calibrated for ASCII/Latin text (~4 chars/token).
    # For CJK languages (Chinese, Japanese, Korean) the actual token count is
    # approximately 4× higher than the estimate because CJK characters are
    # typically 1 token each in GPT-4/Claude tokenizers (~1 char/token vs the
    # 4 char/token assumed here).  Use a tokenizer-backed callable via
    # +.tokenizer=+ for accurate CJK token counting.
    #
    # Replace the built-in heuristic with any callable via .tokenizer=:
    #
    # @example Use tiktoken_ruby for accurate GPT token counts
    #   require "tiktoken_ruby"
    #   enc = Tiktoken.encoding_for_model("gpt-4o")
    #   Phronomy::Context::TokenEstimator.tokenizer = ->(text) { enc.encode(text).length }
    #
    # @example Reset to built-in heuristic
    #   Phronomy::Context::TokenEstimator.tokenizer = nil
    module TokenEstimator
      @tokenizer = nil
      @tokenizer_mutex = Mutex.new

      class << self
        # Replace the built-in heuristic with a callable that takes a String
        # and returns an Integer token count.  Set to nil to restore the default.
        #
        # @note This is a process-wide setting. Set it once at application startup.
        #   In tests, call +TokenEstimator.reset_tokenizer!+ after each test to
        #   prevent cross-test contamination.
        # @param callable [#call, nil]
        # @api private
        def tokenizer=(callable)
          @tokenizer_mutex.synchronize { @tokenizer = callable }
        end

        # @return [#call, nil]
        # @api private
        def tokenizer
          @tokenizer_mutex.synchronize { @tokenizer }
        end

        # Resets the tokenizer to the built-in heuristic. Intended for test isolation.
        def reset_tokenizer!
          @tokenizer_mutex.synchronize { @tokenizer = nil }
        end

        # Estimate the number of tokens for the given input.
        #
        # @param input [String, Array, #content] a string, a message-like object,
        #   or an Array of message-like objects (each must respond to #content).
        # @return [Integer] estimated token count (>= 0)
        # @api private
        def estimate(input)
          tok = @tokenizer_mutex.synchronize { @tokenizer }
          case input
          when String
            tok ? tok.call(input) : (input.length / 4.0).ceil
          when Array
            input.sum { |m| estimate(m.content.to_s) }
          else
            estimate(input.content.to_s)
          end
        end
      end
    end
  end
end
