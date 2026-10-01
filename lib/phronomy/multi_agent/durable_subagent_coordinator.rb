# frozen_string_literal: true

require "digest"

module Phronomy
  module MultiAgent
    # Owns slot reservations and import progress. The Agent participant stores
    # only this binding's opaque state reference alongside its own transition.
    # @api private
    class DurableSubagentCoordinator
      BINDING_KEY = "phronomy.subagent"
      attr_reader :persistence

      def initialize(agent_class:, persistence:)
        @agent_class, @persistence = agent_class, persistence
        @definitions = agent_class.registered_subagents
      end

      def binding
        Phronomy::Agent::ExecutionExtensionState.new(binding_key: BINDING_KEY, binding_version: 1)
      end

      def guard_change(change, scope)
        snapshot = state_for(change.extension)
        ids = [change.agent_id] + snapshot.fetch("children").filter_map do |child|
          child.fetch("agent_id") if persistence.agent_store.exist?(child.fetch("agent_id"))
        end
        persistence.agent_store.guard_agents(scope, agent_ids: ids)
      end

      # The referenced content is immutable and is part of Agent's commit proof.
      def change_evidence(change, scope)
        persistence.agent_store.retained_references(agent_id: change.agent_id, scope: scope).map(&:to_h)
      end

      def commit(change)
        persistence.coordinator.atomic do |scope|
          guard_change(change, scope)
          change.prepare_in(scope)
          snapshot = state_for(change.extension)
          children = snapshot.fetch("children").map(&:dup)
          cancelled = snapshot["cancel_requested"] || change.cancel_requested ||
            persistence.agent_store.cancellation_requested?(agent_id: change.agent_id, execution_id: change.execution_id, scope: scope)
          children.each do |child|
            observed = persistence.agent_store.observe_execution(agent_id: child.fetch("agent_id"), execution_id: child.fetch("execution_id"), scope: scope)
            # This is import progress, not a replicated child execution state.
            child["imported"] = true if observed.terminal? && change.kind == :dispatch && change.operations.empty?
          end
          change.operations.each do |operation|
            entry = @definitions.find { |name, _| "dispatch_to_#{name}" == operation.name }
            next unless entry
            next if children.any? { |child| child.fetch("slot") == operation.invocation_id }
            name, settings = entry
            digest = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(
              ["phronomy-subagent-v1", change.agent_id, change.execution_id, operation.invocation_id]
            ))
            knowledge = settings.fetch(:inherit_knowledge) ? persistence.agent_store.knowledge_snapshot(agent_id: change.agent_id, scope: scope) : []
            children << {"slot" => operation.invocation_id, "name" => name.to_s,
                         "definition" => settings.fetch(:agent_class).agent_definition.transform_keys(&:to_s),
                         "agent_id" => "subagent-#{digest}", "execution_id" => "subagent-execution-#{digest}",
                         "input" => operation.arguments.fetch("input"), "durable_context" => change.durable_context,
                         "knowledge" => knowledge.map { |item| {"content" => item.content, "metadata" => item.metadata} },
                         "on_error" => settings.fetch(:on_error).to_s, "imported" => false}
          end
          unless children.empty?
            persistence.agent_store.retain(Phronomy::Agent::Retention.new(agent_id: change.agent_id,
              execution_id: change.execution_id, owner_key: "subagent:#{change.execution_id}"), scope: scope)
          end
          unresolved = children.any? do |child|
            observed = persistence.agent_store.observe_execution(agent_id: child.fetch("agent_id"), execution_id: child.fetch("execution_id"), scope: scope)
            observed.active? || (observed.absent? && !cancelled)
          end
          persistence.participate(scope) do |records|
            ref = records.contents.put_json(snapshot.merge("children" => children, "cancel_requested" => !!cancelled))
            state = Phronomy::Agent::ExecutionExtensionState.new(binding_key: BINDING_KEY, binding_version: 1, state_ref: ref)
            change.commit_in(scope, state: state,
              pending: change.kind == :terminal && unresolved && (change.cancel_requested || change.recovery_required))
          end
        end
      end

      def state_for(extension)
        extension&.state_ref ? persistence.contents.fetch_json(extension.state_ref) : {"children" => [], "cancel_requested" => false}
      end

      def self.start(parent:, tool_invocation_id:, parent_execution_id:, config:)
        completion = Phronomy::TaskResult.deferred(name: "durable-subagent:#{tool_invocation_id}")
        preparation = Phronomy::Execution.submit(on_full: :raise) do
          store = parent.coordination_store
          extension = parent.persistence.execution_extension(agent_id: parent.agent_id, execution_id: parent_execution_id, binding_key: BINDING_KEY)
          raise Phronomy::ExecutionRehydrationRequiredError, "Missing subagent reservation state" unless extension&.state_ref
          snapshot = store.contents.fetch_json(extension.state_ref)
          child = snapshot.fetch("children").find { |entry| entry.fetch("slot") == tool_invocation_id }
          raise Phronomy::ExecutionRehydrationRequiredError, "Missing reserved child slot" unless child
          settings = parent.class.registered_subagents.find { |name, _| name.to_s == child.fetch("name") }&.last
          unless settings && settings.fetch(:agent_class).agent_definition.transform_keys(&:to_s) == child.fetch("definition")
            raise Phronomy::ConfigurationError, "Registered child definition changed"
          end
          klass = settings.fetch(:agent_class)
          id = child.fetch("agent_id")
          retention = Phronomy::Agent::Retention.new(agent_id: id, execution_id: child.fetch("execution_id"), owner_key: "subagent:#{parent_execution_id}")
          agent = klass.get(id)
          unless agent
            if parent.persistence.exist?(id)
              agent = klass.load(id, persistence: parent.persistence, on_event: parent.event_listener)
            else
              raise Phronomy::CancellationError, "Parent reservation was cancelled" if snapshot["cancel_requested"]
              knowledge = child.fetch("knowledge").map { |item| Phronomy::Agent::KnowledgeItem.new(content: item.fetch("content"), metadata: item.fetch("metadata")) }
              agent = klass.create(agent_id: id, persistence: parent.persistence, knowledge: knowledge,
                retention: retention, on_event: parent.event_listener)
            end
          end
          raise Phronomy::ConfigurationError, "Child Persistence mismatch" unless agent.persistence.equal?(parent.persistence)
          [child, agent, store]
        end
        preparation.on_complete do |prepared, failure|
          if failure
            completion.fail(failure.is_a?(Phronomy::CancellationError) ? failure : Phronomy::ExecutionRehydrationRequiredError.new("Child reservation requires recovery: #{failure.message}"))
            next
          end
          child, agent, store = prepared
          owner = {"kind" => "subagent", "parent_execution_id" => parent_execution_id,
                   "parent_agent_id" => parent.agent_id, "slot" => tool_invocation_id}
          child_config = {cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new,
                          invocation_context: config[:invocation_context],
                          phronomy_admission: ReservedChildAdmission.new(persistence: store, owner: owner)}.compact
          child_config[:durable_context] = child["durable_context"] if child["durable_context"]
          reservation = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: child.fetch("execution_id"), correlation: owner)
          agent.start_reserved_async(reservation: reservation, input: child.fetch("input"), config: child_config).on_complete do |result, error|
            if error
              completion.fail(error.is_a?(Phronomy::CancellationError) ? error : Phronomy::ExecutionRehydrationRequiredError.new("Child #{reservation.execution_id} is unfinished: #{error.message}"))
            elsif result[:error]
              if child.fetch("on_error") == "skip" && result[:status] != :cancelled
                completion.complete(nil)
              else
                observed = Phronomy::Agent::ExecutionObservation.from_result(result)
                begin
                  observed.value!
                rescue => failure
                  completion.fail(failure)
                end
              end
            else
              completion.complete(result[:output])
            end
          end
        rescue => error
          completion.fail(error)
        end
        completion
      rescue => error
        completion ||= Phronomy::TaskResult.deferred(name: "durable-subagent")
        completion.fail(error)
        completion
      end
    end
  end
end
