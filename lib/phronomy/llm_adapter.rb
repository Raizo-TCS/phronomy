# frozen_string_literal: true

module Phronomy
  # Namespace for LLM adapter implementations.
  #
  # An LLMAdapter decouples Phronomy's agent pipeline from direct
  # dependency on the RubyLLM blocking client. All LLM calls in
  # {Agent::Base} are routed through the adapter so that:
  #
  # - Blocking HTTP can be submitted to {BlockingAdapterPool} for bounded
  #   concurrency and per-operation timeouts.
  # - Alternative LLM clients can be swapped in without changing agent code.
  #
  # @example Configuring a custom adapter
  #   Phronomy.configure do |c|
  #     c.llm_adapter = MyCustomAdapter.new
  #   end
  module LLMAdapter
  end
end
