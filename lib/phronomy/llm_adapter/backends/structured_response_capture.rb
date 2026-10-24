# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # RubyLLM 2.0 drops refusal fields when creating streaming Chunk values.
    # Use its Protocol subclass seam on this operation's Provider only; never
    # patch global SDK classes or retain an application callback across calls.
    # @api private
    class StructuredResponseCapture
      attr_reader :refusal, :raw_finish_reason

      def bind(chat)
        capture = self
        protocols = chat.provider.protocols.transform_values do |base|
          Class.new(base) do
            define_method(:build_chunk) do |data|
              capture.record(data)
              super(data)
            end
          end
        end.freeze
        chat.provider.define_singleton_method(:protocols) { protocols }
      end

      def record(data)
        choice = data.dig("choices", 0) || {}
        provider_delta = data["delta"]
        stop_reason = provider_delta["stop_reason"] if provider_delta.is_a?(Hash)
        @raw_finish_reason = choice["finish_reason"] || stop_reason ||
          data.dig("candidates", 0, "finishReason") || @raw_finish_reason
        delta = choice.dig("delta", "refusal")
        delta ||= data["delta"] if data["type"] == "response.refusal.delta"
        @refusal = (@refusal || "") + delta if delta.is_a?(String)
        final = data["response"]
        return unless final.is_a?(Hash)
        refusals = Array(final["output"]).flat_map { |item| Array(item["content"]) }
          .select { |item| item["type"] == "refusal" }.map { |item| item["refusal"] }
        @refusal = refusals.join("\n") unless refusals.empty?
        @raw_finish_reason = final.dig("incomplete_details", "reason") || final["status"] || @raw_finish_reason
      end
    end
  end
end
