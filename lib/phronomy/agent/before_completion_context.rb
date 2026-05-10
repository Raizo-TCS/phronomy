# frozen_string_literal: true

module Phronomy
  module Agent
    # Passed to every before_completion hook callable.
    # Provides read access to the agent, assembled messages, and invocation config.
    # Hooks may inspect these and return a Hash of params to merge into the LLM request.
    #
    # @example Reading context inside a hook
    #   Phronomy.configure do |cfg|
    #     cfg.before_completion = lambda do |ctx|
    #       Rails.logger.info "LLM request: model=#{ctx.params[:model]}"
    #       { temperature: 0.2 }
    #     end
    #   end
    class BeforeCompletionContext
      # The agent instance making the LLM call.
      # @return [Phronomy::Agent::Base]
      attr_reader :agent

      # Messages currently assembled for this invocation (read-only snapshot).
      # @return [Array]
      attr_reader :messages

      # Runtime config hash passed to invoke/stream (e.g. thread_id, memory).
      # @return [Hash]
      attr_reader :config

      # Current LLM params being built (model, temperature, etc.).
      # Read-only; return a Hash from the hook to merge overrides.
      # @return [Hash]
      attr_reader :params

      # @param agent    [Phronomy::Agent::Base]
      # @param messages [Array]
      # @param config   [Hash]
      # @param params   [Hash] initial params (model, temperature already set on chat)
      def initialize(agent:, messages:, config:, params: {})
        @agent = agent
        @messages = messages.dup.freeze
        @config = config
        @params = params.dup.freeze
      end
    end
  end
end
