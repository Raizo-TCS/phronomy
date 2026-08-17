# frozen_string_literal: true

module Phronomy
  # Namespace for LLM call adapters.
  #
  # The public extension boundary is {LLMAdapter::Base#complete} and
  # {LLMAdapter::Base#stream}. Those methods receive Phronomy's currently
  # materialized chat/runtime object and perform the provider call. Phronomy owns
  # the async/offload bridge around that synchronous contract.
  #
  # This SPI does not by itself make the complete input-materialization pipeline
  # provider-neutral: the current Agent pipeline still materializes the canonical
  # LLM input through RubyLLM-specific runtime objects before invoking the adapter.
  #
  # @example Configuring a custom adapter
  #   Phronomy.configure do |c|
  #     c.llm_adapter = MyCustomAdapter.new
  #   end
  #
  # @api public
  module LLMAdapter
  end
end
