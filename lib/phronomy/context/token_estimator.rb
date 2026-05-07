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
    # English text averages ~4 chars/token; Japanese text averages ~2 chars/token
    # so this is a slight underestimate for Japanese.
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

      class << self
        # Replace the built-in heuristic with a callable that takes a String
        # and returns an Integer token count.  Set to nil to restore the default.
        #
        # @param callable [#call, nil]
        attr_accessor :tokenizer

        # Estimate the number of tokens for the given input.
        #
        # @param input [String, Array, #content] a string, a message-like object,
        #   or an Array of message-like objects (each must respond to #content).
        # @return [Integer] estimated token count (>= 0)
        def estimate(input)
          case input
          when String
            @tokenizer ? @tokenizer.call(input) : (input.length / 4.0).ceil
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
