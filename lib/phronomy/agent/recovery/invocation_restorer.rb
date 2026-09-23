# frozen_string_literal: true

module Phronomy
  module Agent
    # Reconstructs operation-local live objects from already materialized facts.
    # Persistence reads stay with SavedContextReader and the recovery preparer.
    # @api private
    module InvocationRestorer
      module_function

      def build_invocation_for_suspended(agent, execution, projection, main_coordinator, listener, assistant_message:)
        request = execution.approval_request && Phronomy::Agent::ToolApprovalRequest.from_h(
          execution.approval_request
        )
        assistant_record = SavedContextReader.latest_assistant_record(execution)
        unless assistant_record
          raise Phronomy::ExecutionRehydrationRequiredError,
            "suspended execution #{execution.execution_id} has no durable assistant Tool Call message"
        end

        invocation, chat, config = prepare_invocation(agent, execution, projection, main_coordinator, listener)
        chat.messages << assistant_message

        invocation.chat = chat
        invocation.user_message_sent = true
        invocation.approval_request = request
        invocation.instance_variable_set(
          :@tool_batch_llm_call_id,
          assistant_record.llm_call_id&.to_s
        )

        by_id = (request ? request.items : []).to_h do |item|
          [item.tool_invocation_id.to_s, item]
        end
        snapshots = Array(execution.metadata[ExecutionMetadata::TOOL_BATCH_METADATA_KEY])
        if snapshots.empty?
          raise Phronomy::ExecutionRehydrationRequiredError,
            "suspended execution #{execution.execution_id} predates the durable Tool batch snapshot"
        end

        calls_by_id = if assistant_message.tool_calls.respond_to?(:values)
          assistant_message.tool_calls.values.to_h do |call|
            [call.id.to_s, call]
          end
        else
          Array(assistant_message.tool_calls).to_h do |call|
            [call.id.to_s, call]
          end
        end

        children = snapshots.map do |snapshot|
          entry = snapshot.to_h { |key, value| [key.to_s, value] }
          call = calls_by_id.fetch(entry.fetch("tool_call_id").to_s) do
            raise Phronomy::ExecutionRehydrationRequiredError,
              "Tool Call #{entry.fetch("tool_call_id")} is missing from the durable assistant message"
          end
          tool = chat.tools[entry.fetch("tool_name").to_sym]
          child = if tool
            Phronomy::Agent::ToolInvocation.new(
              execution_id: execution.execution_id,
              agent: agent,
              tool: tool,
              tool_call: call,
              config: config,
              id: entry.fetch("tool_invocation_id")
            )
          else
            Phronomy::Agent::ToolInvocation.missing(
              execution_id: execution.execution_id,
              agent: agent,
              tool_call: call,
              config: config,
              id: entry.fetch("tool_invocation_id")
            )
          end
          child.restore_state!(
            status: entry.fetch("status").to_sym,
            result: entry["result"],
            approval_item: by_id[child.id.to_s]
          )
        end
        invocation.tool_invocations = children
        invocation
      end

      def build_chat_for_recovery(agent, execution, projection, main_coordinator, listener, messages:)
        invocation, chat = prepare_invocation(agent, execution, projection, main_coordinator, listener)

        messages.each { |message| chat.messages << message }

        invocation.chat = chat
        invocation.user_message_sent = true
        invocation
      end

      def prepare_invocation(agent, execution, projection, main_coordinator, listener)
        config = {
          execution_id: execution.execution_id,
          phronomy_execution_coordinator: main_coordinator,
          phronomy_runtime_projection: projection
        }.merge(agent.__coordination_config)
        config = agent.__invocation_config(config)
        if execution.metadata["coordination_cancel_requested"]
          config = config.merge(cancellation_token: Phronomy::Concurrency::CancellationToken.new.cancel!)
        end
        invocation = Phronomy::Agent::AgentInvocation.new(
          agent: agent,
          input: projection.ask_message,
          config: config,
          event_listener: listener,
          mode: (execution.metadata[ExecutionMetadata::INVOCATION_MODE_KEY] || "invoke").to_sym,
          execution_id: execution.execution_id
        )
        chat = agent.send(:build_chat, model_config: projection.model_config)
        agent.send(
          :_apply_runtime_projection_to_chat,
          chat,
          projection,
          invocation: invocation
        )
        if projection.ask_message
          chat.messages << RubyLLM::Message.new(
            role: :user,
            content: projection.ask_message
          )
        end
        [invocation, chat, config]
      end
      private_class_method :prepare_invocation
    end
  end
end
