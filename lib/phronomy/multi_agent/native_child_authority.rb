# frozen_string_literal: true

require "digest"

module Phronomy
  module MultiAgent
    # Detached native child identities and current authority. Saving a captured
    # outcome permits legal child progress; dispatch requires terminal or absent
    # relationships before starting its still-unused continuation.
    # @api private
    class NativeChildAuthority
      attr_reader :agent_ids

      def initialize(agent_id:, execution_id:, children:, prior_slots:, persistence:)
        @agent_id, @execution_id = agent_id, execution_id
        @children = Phronomy::Values::Immutable.copy(children)
        @prior_slots = Phronomy::Values::Immutable.copy(prior_slots)
        @persistence_identity = persistence.execution_evidence_identity
        validate_identities!
        @agent_ids = ([@agent_id] + @children.map { |child| child.fetch("agent_id") }).uniq.sort.freeze
        freeze
      end

      # Existing roots can be guarded. Authoritative absence is not a durable
      # reservation extending beyond this transaction.
      def guarded_agent_ids(persistence:, scope:)
        validate_store!(persistence)
        agent_ids.select { |id| id == @agent_id || read_root(persistence, scope, id) }
      end

      def assert_current!(persistence:, scope:, outcome: false)
        validate_store!(persistence)
        @children.each do |child|
          id, execution_id = child.fetch("agent_id"), child.fetch("execution_id")
          root = read_root(persistence, scope, id)
          observed = persistence.observe_execution(agent_id: id, execution_id: execution_id, scope: scope)
          if !@prior_slots.include?(child.fetch("slot"))
            unless root.nil? && observed.absent?
              raise Phronomy::Persistence::StateConflictError, "Reserved native child appeared before continuation"
            end
            next
          end
          acknowledgement = child["terminal_acknowledgement"]
          next if root.nil? && observed.absent? && !child.fetch("imported") && !acknowledgement

          reservation = Phronomy::Agent::ReservedExecution.new(agent_id: id,
            execution_id: execution_id, correlation: self.class.correlation(@agent_id, @execution_id, child))
          definition = child.fetch("definition")
          hold = Phronomy::Agent::Retention.new(agent_id: id, execution_id: execution_id,
            owner_key: "subagent:#{@execution_id}")
          allowed_status = observed.terminal? || (outcome && !child.fetch("imported") && !acknowledgement &&
            observed.active?)
          unless root && root.agent_definition_id == definition.fetch("id") &&
              root.agent_definition_version == definition.fetch("version") && allowed_status &&
              observed.reservation == reservation && persistence.retained_references(agent_id: id, scope: scope).include?(hold)
            raise Phronomy::Persistence::StateConflictError, "Native child authority changed before application"
          end
          if acknowledgement && acknowledgement != self.class.terminal_acknowledgement(@agent_id, @execution_id, child, observed)
            raise Phronomy::Persistence::StateConflictError, "Native terminal child acknowledgement changed before replay"
          end
        end
        nil
      end

      def self.correlation(parent_id, parent_execution_id, child)
        {"kind" => "subagent", "parent_agent_id" => parent_id,
         "parent_execution_id" => parent_execution_id, "slot" => child.fetch("slot")}
      end

      def self.terminal_acknowledgement(parent_id, parent_execution_id, child, observed)
        owner = correlation(parent_id, parent_execution_id, child)
        reservation = Phronomy::Agent::ReservedExecution.new(agent_id: child.fetch("agent_id"),
          execution_id: child.fetch("execution_id"), correlation: owner)
        return unless observed.terminal? && observed.reservation == reservation

        # Cancellation intent and retention changes do not rewrite this result.
        # The receipt identifies immutable child history without copying it.
        outcome = {"result" => observed.result, "raw_output" => observed.raw_output,
                   "error" => observed.error, "transfer_receipt" => observed.transfer_receipt}
        {"version" => 1, "agent_id" => observed.agent_id, "execution_id" => observed.execution_id,
         "reservation" => owner, "status" => observed.status.to_s,
         "outcome_digest" => Digest::SHA256.hexdigest(JSON.generate(ordered_outcome_value(outcome)))}
      end

      def self.ordered_outcome_value(value)
        # Results allow integers beyond Canonical JSON's safe number range.
        # Order keys without narrowing the accepted JSON result values.
        case value
        when Hash then value.keys.sort.to_h { |key| [key, ordered_outcome_value(value.fetch(key))] }
        when Array then value.map { |item| ordered_outcome_value(item) }
        else value
        end
      end
      private_class_method :ordered_outcome_value

      private

      def validate_identities!
        unless @children.map { |child| child.fetch("slot") }.uniq.size == @children.size &&
            @children.map { |child| child.fetch("agent_id") }.uniq.size == @children.size
          raise Phronomy::Persistence::StateConflictError, "Native child identities are not unique"
        end
        @children.each do |child|
          digest = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(
            ["phronomy-subagent-v1", @agent_id, @execution_id, child.fetch("slot")]
          ))
          unless child.fetch("agent_id") == "subagent-#{digest}" &&
              child.fetch("execution_id") == "subagent-execution-#{digest}"
            raise Phronomy::Persistence::StateConflictError, "Native child identity differs from its slot"
          end
        end
      end

      def read_root(persistence, scope, id)
        persistence.participate(scope) do |records|
          records.agents.load(id)
        rescue Phronomy::Persistence::NotFoundError
          nil
        end
      end

      def validate_store!(persistence)
        unless persistence.execution_evidence_identity.equal?(@persistence_identity)
          raise Phronomy::Persistence::StateConflictError, "Native child proof belongs to another Store"
        end
      end
    end
  end
end
