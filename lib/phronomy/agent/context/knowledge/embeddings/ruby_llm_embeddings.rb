# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Knowledge
        module Embeddings
    # Embeddings adapter backed by RubyLLM.
    #
    # Delegates to +RubyLLM.embed+ and returns the resulting vector as an
    # +Array<Float>+.
    #
    # @example Default model
    #   embeddings = Phronomy::Agent::Context::Knowledge::Embeddings::RubyLLMEmbeddings.new
    #   vector = embeddings.embed("Hello, world!")
    #
    # @example Explicit model
    #   embeddings = Phronomy::Agent::Context::Knowledge::Embeddings::RubyLLMEmbeddings.new(model: "text-embedding-3-small")
    #   vector = embeddings.embed("Hello, world!")
    class RubyLLMEmbeddings < Base
      # @param model               [String, nil] embedding model identifier; nil uses the RubyLLM default
      # @param provider            [Symbol, nil] provider override (e.g. :openai); nil uses the RubyLLM default
      # @param assume_model_exists [Boolean]     when true, skips RubyLLM model-registry validation
      #                                          (useful for locally hosted models not in the registry)
      # @api public
      def initialize(model: nil, provider: nil, assume_model_exists: false)
        @model = model
        @provider = provider
        @assume_model_exists = assume_model_exists
      end

      # Embed text via RubyLLM.
      #
      # @param text               [String]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] optional; raises CancellationError when cancelled
      # @return [Array<Float>]
      # @api public
      def embed(text, cancellation_token = nil)
        cancellation_token&.raise_if_cancelled!
        opts = {}
        opts[:model] = @model if @model
        opts[:provider] = @provider if @provider
        opts[:assume_model_exists] = true if @assume_model_exists
        RubyLLM.embed(text, **opts).vectors
      end
    end
  end
end
end
end
end
