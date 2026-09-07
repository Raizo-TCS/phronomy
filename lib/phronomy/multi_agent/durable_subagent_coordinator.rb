# frozen_string_literal: true

require "securerandom"

module Phronomy
  module MultiAgent
    # Agent-owned transactions reserve child work; Task callbacks only wake observers.
    # @api private
    class DurableSubagentCoordinator
      KEY = "multi_agent_coordination_ref"

      def self.prepare(parent, execution, tx:)
        ref = execution.metadata[KEY]
        snapshot = ref ? tx.contents.fetch_json(ref) : {"kind" => "static_subagent", "children" => []}
        children = snapshot.fetch("children").map(&:dup)
        children.each do |child|
          begin
            exact = tx.executions.load(child.fetch("execution_id"))
          rescue Phronomy::Persistence::NotFoundError
            next
          end
          raise Phronomy::Persistence::ConflictError, "Child owner mismatch" unless exact.agent_id == child.fetch("agent_id")
          child.merge!("state" => exact.status.to_s, "result_ref" => exact.result_ref, "error_ref" => exact.error_ref)
        end
        Array(execution.metadata[Phronomy::Agent::RecoverySupport::TOOL_BATCH_METADATA_KEY]).each do |tool|
          registration = parent.class.registered_subagents.find { |name, _| "dispatch_to_#{name}" == tool.fetch("tool_name") }
          next unless registration
          next if children.any? { |child| child.fetch("slot") == tool.fetch("tool_invocation_id") }
          name, settings = registration
          definition = settings.fetch(:agent_class).agent_definition
          knowledge = settings.fetch(:inherit_knowledge) ? parent.send(:active_knowledge_snapshot) : []
          children << {
            "slot" => tool.fetch("tool_invocation_id"), "name" => name.to_s,
            "definition" => definition.transform_keys(&:to_s),
            "agent_id" => SecureRandom.uuid, "execution_id" => SecureRandom.uuid,
            "input_ref" => tx.contents.put_text(tool.fetch("arguments").fetch("input")),
            "durable_context_ref" => execution.metadata["durable_context_ref"],
            "knowledge_ref" => tx.contents.put_json(Phronomy::Agent::RecoverySupport.canonical_copy(knowledge)),
            "state" => "reserved", "result_ref" => nil, "error_ref" => nil,
            "on_error" => settings.fetch(:on_error).to_s
          }
        end
        return execution if children.empty?
        value = tx.contents.put_json(snapshot.merge("children" => children))
        execution.with(execution_revision: execution.execution_revision, metadata: execution.metadata.merge(KEY => value))
      end

      def self.start(parent:, tool_invocation_id:, parent_execution_id:, config:)
        runtime = Phronomy::Runtime.instance
        completion = Phronomy::Task.deferred(name: "durable-subagent:#{tool_invocation_id}")
        preparation = runtime.offload.submit(on_full: :raise) do
          current = parent.persistence.executions.load(parent_execution_id)
          raise Phronomy::Persistence::ConflictError, "Parent owner mismatch" unless current.agent_id == parent.agent_id
          snapshot = parent.persistence.contents.fetch_json(current.metadata.fetch(KEY))
          child = snapshot.fetch("children").find { |entry| entry.fetch("slot") == tool_invocation_id }
          raise Phronomy::ExecutionRehydrationRequiredError, "Missing reserved child slot" unless child
          definition = parent.class.registered_subagents.find { |name, _| name.to_s == child.fetch("name") }&.last
          unless definition && definition.fetch(:agent_class).agent_definition.transform_keys(&:to_s) == child.fetch("definition")
            raise Phronomy::ConfigurationError, "Registered child definition changed: #{child.fetch("name")}"
          end
          klass = definition.fetch(:agent_class)
          id = child.fetch("agent_id")
          agent = klass.get(id)
          unless agent
            begin
              parent.persistence.agents.load(id)
              exists = true
            rescue Phronomy::Persistence::NotFoundError
              exists = false
            end
            listener = parent.send(:_phronomy_event_listener)
            agent = if exists
              klass.load(id, persistence: parent.persistence, on_event: listener)
            else
              knowledge = parent.persistence.contents.fetch_json(child.fetch("knowledge_ref"))
              context = Phronomy::Agent::ContextImporter::ImportedContext.new(records: knowledge.map do |item|
                Phronomy::Agent::ContextImporter::ImportedRecord.new(kind: :knowledge,
                  channel: :context, role: :user, content: item.fetch("content"),
                  content_format: :text, metadata: item.fetch("metadata"))
              end)
              klass.create(agent_id: id, persistence: parent.persistence,
                context: context, on_event: listener)
            end
          end
          unless agent.persistence.equal?(parent.persistence)
            raise Phronomy::ConfigurationError, "Child Persistence instance mismatch"
          end
          durable_context = child["durable_context_ref"] && parent.persistence.contents.fetch_json(child["durable_context_ref"])
          [child, agent, parent.persistence.contents.fetch_text(child.fetch("input_ref")), durable_context]
        end
        preparation.on_complete do |prepared, failure|
          if failure
            completion.fail(Phronomy::ExecutionRehydrationRequiredError.new("Child reservation requires recovery: #{failure.message}"))
            next
          end
          child, agent, input, durable_context = prepared
          child_config = {cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new,
                          invocation_context: config[:invocation_context],
                          phronomy_coordination: {"kind" => "subagent", "parent_execution_id" => parent_execution_id,
                                                  "parent_agent_id" => parent.agent_id, "slot" => tool_invocation_id}}.compact
          child_config = child_config.merge(durable_context: durable_context) if child["durable_context_ref"]
          source = Phronomy::Agent::ExactExecution.start(agent: agent,
            execution_id: child.fetch("execution_id"), input: input, config: child_config)
          source.on_complete do |result, error|
            if error
              if error.is_a?(Phronomy::CancellationError)
                completion.fail(error)
              else
                completion.fail(Phronomy::ExecutionRehydrationRequiredError.new(
                  "Child #{child.fetch("execution_id")} is unfinished: #{error.message}"
                ))
              end
            elsif result[:error]
              if child.fetch("on_error") == "skip"
                completion.complete(nil)
              else
                completion.fail(Phronomy::Agent::RecoverySupport.error_from_failure(result[:error]))
              end
            else
              completion.complete(result[:output])
            end
          end
        rescue => error
          completion.fail(Phronomy::ExecutionRehydrationRequiredError.new("Child coordination requires recovery: #{error.message}"))
        end
        completion
      rescue => error
        completion ||= Phronomy::Task.deferred(name: "durable-subagent")
        completion.fail(error)
        completion
      end
    end
  end
end
