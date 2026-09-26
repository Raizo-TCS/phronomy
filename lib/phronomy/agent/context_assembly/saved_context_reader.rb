# frozen_string_literal: true

module Phronomy
  module Agent
    # Reads saved manifests and Provider output for continuation preparation.
    # Callers perform these reads before applying live state on EventLoop.
    # @api private
    module SavedContextReader
      module_function

      def manifest_from_ref(agent, ref)
        Phronomy::Persistence::StorageBoundary.call do
          raw = agent.persistence.contents.fetch_json(ref)
          Phronomy::Agent::LLMInputManifest.from_h(raw)
        end
      end

      def materialize_projection(agent, manifest_ref)
        manifest = manifest_from_ref(agent, manifest_ref)
        projection = Phronomy::Agent::RubyLLMMaterializer.new(
          agent: agent,
          persistence: agent.persistence
        ).materialize(manifest: manifest, manifest_ref: manifest_ref)
        [manifest, projection]
      end

      def latest_assistant_record(execution, llm_call_id: nil)
        Array(execution.working_records).reverse.find do |record|
          record.kind.to_sym == :assistant_message &&
            (llm_call_id.nil? || record.llm_call_id.to_s == llm_call_id.to_s)
        end
      end

      def provider_output_and_usage(agent, execution)
        assistant = latest_assistant_record(execution)
        payload = assistant ? agent.persistence.contents.fetch_json(assistant.content_ref) : {}
        output = payload["content"]

        call = execution.llm_calls.last
        usage_hash = if call&.usage_ref
          agent.persistence.contents.fetch_json(call.usage_ref)
        else
          {}
        end
        usage = Phronomy::TokenUsage.new(
          input: usage_hash["input"] || usage_hash[:input] || usage_hash["input_tokens"] || usage_hash[:input_tokens],
          output: usage_hash["output"] || usage_hash[:output] || usage_hash["output_tokens"] || usage_hash[:output_tokens],
          cached: usage_hash["cached"] || usage_hash[:cached] || usage_hash["cache_read_tokens"] || usage_hash[:cache_read_tokens] || usage_hash["cached_tokens"] || usage_hash[:cached_tokens],
          cache_creation: usage_hash["cache_creation"] || usage_hash[:cache_creation] || usage_hash["cache_write_tokens"] || usage_hash[:cache_write_tokens] || usage_hash["cache_creation_tokens"] || usage_hash[:cache_creation_tokens]
        )
        [output, usage]
      end
    end
  end
end
