# frozen_string_literal: true

module Phronomy
  module Agent
    # Constructs provider chat objects from already selected model settings.
    # Agent hooks retain projection installation and invocation-specific Tools.
    # @api private
    class RuntimeChatBuilder
      def self.build(config)
        chat = RubyLLM.chat(**chat_options(config))
        chat.with_temperature(config["temperature"]) if config["temperature"]
        if config["max_output_tokens"] && chat.respond_to?(:with_max_output_tokens)
          chat.with_max_output_tokens(config["max_output_tokens"])
        end
        chat
      end

      def self.apply_instructions(chat, text, cache:, provider:)
        if cache && provider.to_s == "anthropic"
          content = RubyLLM::Providers::Anthropic::Content.new(text, cache: true)
          chat.with_instructions(content)
        else
          chat.with_instructions(text)
        end
      end

      def self.chat_options(config)
        opts = {}
        model = config["model"]
        opts[:model] = model if model
        provider = config["provider"]
        if provider
          opts[:provider] = provider.to_sym
          opts[:assume_model_exists] = true
        end
        opts
      end
      private_class_method :chat_options
    end
  end
end
