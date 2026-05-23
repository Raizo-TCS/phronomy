# frozen_string_literal: true

module Phronomy
  module Agent
    module Concerns
      # Adds before_completion hook support to an agent.
      #
      # Included in {Phronomy::Agent::Base}. Hooks are executed just before every
      # LLM call (global → class → instance order) and may inject or override
      # LLM parameters such as temperature or model.
      # @api private
      module BeforeCompletion
        def self.included(base)
          base.extend(ClassMethods)
        end

        # Class-level DSL methods mixed into the including agent class.
        module ClassMethods
          # Sets or reads the class-level before_completion hook.
          # The hook is called before every LLM request for instances of this class.
          # Receives a {Phronomy::Agent::BeforeCompletionContext}; must return a Hash
          # of params to merge into the LLM call, or nil to pass through unchanged.
          #
          # @param callable [#call, nil] lambda/proc to register, or nil to clear
          # @return [#call, nil]
          # @example
          #   class MyAgent < Phronomy::Agent::Base
          #     before_completion ->(ctx) { { temperature: 0.2 } }
          #   end
          # @api private
          def before_completion(callable = nil)
            if callable.nil? && !block_given?
              @before_completion
            else
              @before_completion = callable
            end
          end

          # @return [#call, nil]
          # @api private
          def _before_completion
            @before_completion
          end
        end

        # Instance-level before_completion hook. When set, takes precedence over
        # the class-level hook for this specific agent instance only.
        # @return [#call, nil]
        attr_accessor :before_completion

        private

        # Collects and runs all registered before_completion hooks in order
        # (global → class → instance) and applies the merged params to the chat.
        #
        # @param chat   [RubyLLM::Chat] the assembled chat object
        # @param config [Hash] the invocation config hash
        # @return [Hash] the merged params applied to the chat
        # @api private
        def run_before_completion_hooks!(chat, config)
          hooks = [
            Phronomy.configuration.before_completion,
            self.class._before_completion,
            @before_completion
          ].compact

          return {} if hooks.empty?

          ctx = BeforeCompletionContext.new(
            agent: self,
            messages: chat.messages,
            config: config,
            params: {}
          )

          merged = {}
          hooks.each do |hook|
            result = hook.call(ctx)
            check_cancellation!(config, "invocation cancelled during before_completion hook")
            merged.merge!(result) if result.is_a?(Hash)
          end

          apply_before_completion_params!(chat, merged)
          merged
        end

        # Applies a merged param hash returned by before_completion hooks to
        # the chat object using the appropriate RubyLLM::Chat API methods.
        # When overriding the model, reuses the agent's configured provider and
        # assume_exists setting so that local/namespaced models continue to work.
        #
        # @param chat   [RubyLLM::Chat]
        # @param params [Hash]
        # @api private
        def apply_before_completion_params!(chat, params)
          params.each do |key, value|
            case key
            when :model
              prov = self.class.provider
              chat.with_model(value, provider: prov, assume_exists: !prov.nil?)
            when :temperature
              chat.with_temperature(value)
            else
              chat.with_params(key => value)
            end
          end
        end
      end
    end
  end
end
