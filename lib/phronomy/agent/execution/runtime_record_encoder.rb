# frozen_string_literal: true

module Phronomy
  module Agent
    # Encodes execution facts using the caller's existing content transaction.
    # It neither opens a transaction nor changes durable or live execution state.
    # @api private
    module RuntimeRecordEncoder
      module_function

      def encode(
        execution,
        agent_id:,
        tx:,
        snapshot:,
        context_candidate:,
        agent_root:
      )
        root = agent_root
        records = []
        calls = []

        snapshot.fetch(:llm_results).each_with_index do |item, index|
          outcome = item[:response]
          error = item[:error]
          llm_call_id = item.fetch(:llm_call_id).to_s
          intercepted = error.is_a?(ToolCallIntercepted)
          call_error = intercepted ? nil : error
          output_ref = assistant_output_ref(tx, outcome)
          assistant_ref = assistant_message_ref(tx, outcome)
          error_ref = if call_error
            tx.contents.put_json(
              "class" => call_error.class.name,
              "message" => call_error.message
            )
          end
          usage_ref = if outcome && !outcome.usage.empty?
            tx.contents.put_json(json_value(outcome.usage))
          end
          call = LLMCallRecord.new(
            llm_call_id: llm_call_id,
            execution_id: execution.execution_id,
            sequence: execution.llm_calls.length + index + 1,
            status: call_error ? :failed : :completed,
            manifest_ref: item.fetch(:manifest_ref),
            output_ref: output_ref,
            error_ref: error_ref,
            usage_ref: usage_ref,
            started_at: item.fetch(:started_at),
            completed_at: Time.now.utc.iso8601(6),
            metadata: {
              "streaming" => item[:streaming],
              "tool_call_intercepted" => intercepted,
              "assistant_outcome_captured" => !outcome.nil?,
              "tool_call_count" => outcome ? outcome.tool_calls.length : 0
            }
          )
          calls << call
          call_ref = tx.contents.put_json(call.to_h)
          records << JournalRecord.new(
            agent_id: agent_id,
            execution_id: execution.execution_id,
            llm_call_id: llm_call_id,
            kind: :llm_call_recorded,
            channel: :audit,
            content_ref: call_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )

          if assistant_ref
            records << JournalRecord.new(
              agent_id: agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :assistant_message,
              channel: :llm,
              role: :assistant,
              content_ref: assistant_ref,
              context_generation: root.transcript_generation,
              context_candidate: context_candidate,
              metadata: assistant_message_metadata(outcome)
            )
          end
        end

        if (active = snapshot[:active_call])
          abandoned = LLMCallRecord.new(
            llm_call_id: active.fetch(:llm_call_id),
            execution_id: execution.execution_id,
            sequence: execution.llm_calls.length + calls.length + 1,
            status: :cancelled,
            manifest_ref: active.fetch(:manifest_ref),
            started_at: active.fetch(:started_at),
            completed_at: Time.now.utc.iso8601(6),
            metadata: {
              "reason" => "execution_terminalized_before_provider_settlement"
            }
          )
          calls << abandoned
          records << JournalRecord.new(
            agent_id: agent_id,
            execution_id: execution.execution_id,
            llm_call_id: abandoned.llm_call_id,
            kind: :llm_call_recorded,
            channel: :audit,
            content_ref: tx.contents.put_json(abandoned.to_h),
            context_generation: root.transcript_generation,
            context_candidate: false
          )
        end

        snapshot.fetch(:runtime_events).each do |event|
          case event.type
          when :tool_call
            next
          when :tool_result
            payload = event.payload
            llm_call_id = payload[:llm_call_id] || payload["llm_call_id"]
            tool_call_id = payload.fetch(:tool_call_id).to_s
            tool_name = payload.fetch(:tool_name).to_s
            next if execution.working_records.any? do |record|
              record.kind == :tool_message && record.causation_id.to_s == tool_call_id && record.llm_call_id.to_s == llm_call_id.to_s
            end
            result_ref = put_runtime_content(tx, payload.fetch(:tool_result))
            records << JournalRecord.new(
              agent_id: agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :tool_result,
              channel: :tool,
              content_ref: result_ref,
              causation_id: tool_call_id,
              context_generation: root.transcript_generation,
              context_candidate: false,
              metadata: {
                "tool_call_id" => tool_call_id,
                "tool_name" => tool_name
              }
            )

            message_payload = if payload.key?(:tool_message)
              payload.fetch(:tool_message)
            else
              payload.fetch("tool_message")
            end
            records << JournalRecord.new(
              agent_id: agent_id,
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              kind: :tool_message,
              channel: :tool,
              role: :tool,
              content_ref: tx.contents.put_json(json_value(message_payload)),
              causation_id: tool_call_id,
              context_generation: root.transcript_generation,
              context_candidate: context_candidate,
              metadata: {
                "tool_call_id" => tool_call_id,
                "tool_name" => tool_name
              }
            )
          end
        end
        [records, calls]
      end

      def assistant_message_ref(tx, outcome)
        return unless outcome

        payload = {
          "role" => "assistant",
          "content" => json_value(outcome.content),
          "tool_calls" => json_value(Array(outcome.tool_calls)),
          "model_id" => outcome.metadata["model_id"]
        }.compact
        tx.contents.put_json(payload)
      end

      def assistant_message_metadata(outcome)
        calls = Array(outcome&.tool_calls)
        {
          "tool_call_ids" => calls.map { |call| call.fetch("id").to_s },
          "tool_names" => calls.map { |call| call.fetch("name").to_s }
        }
      end

      def assistant_output_ref(tx, outcome)
        return unless outcome&.content_present?

        content = outcome.content
        text = content.is_a?(String) ? content : Phronomy::CanonicalJSON.dump(content)
        tx.contents.put_text(text)
      end

      def put_runtime_content(tx, value)
        value.is_a?(String) ?
          tx.contents.put_text(value) : tx.contents.put_json(json_value(value))
      end

      def json_value(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, json_value(child)] }
        when Array
          value.map { |child| json_value(child) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        when Symbol
          value.to_s
        else
          if value.respond_to?(:to_h)
            json_value(value.to_h)
          else
            raise ArgumentError,
              "unsupported canonical runtime value: #{value.class}"
          end
        end
      end

      private_class_method :assistant_message_ref, :assistant_message_metadata,
        :assistant_output_ref
    end
  end
end
