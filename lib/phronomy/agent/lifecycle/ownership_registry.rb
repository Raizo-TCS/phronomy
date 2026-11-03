# frozen_string_literal: true

module Phronomy
  module Agent
    # Process-local authoritative owner registry for mutable Agent instances.
    #
    # This is not a cache. While a Runtime is alive, one agent_id maps to at most
    # one mutable live Agent object. Construction is reserved before durable
    # create/load so concurrent callers cannot materialize independent objects.
    # @api private
    class OwnershipRegistry
      # Candidates have no side effects. Runtime retains the first registration.
      # Existing instances remain available for lookup and transition completion
      # after admission closes; their own gate rejects new ownership changes.
      def self.current = ExecutionEnvironment.current.ownership
      def self.existing_current = ExecutionEnvironment.current.existing_ownership
      def self.for(environment) = environment.ownership
      def self.existing_for(environment) = environment.existing_ownership

      Entry = Data.define(:state, :agent, :token)
      private_constant :Entry

      def initialize(environment:)
        @environment = environment
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @entries = {}
        @scope_owners = {}
        @operations = {}
        @state = :running
      end

      def create(agent_id, expected_class:, scope_owner: nil)
        key = normalize_agent_id(agent_id)
        token = reserve_create!(key, scope_owner: scope_owner)

        begin
          agent = yield(@environment)
        rescue Phronomy::AgentAlreadyExistsError,
          Phronomy::Persistence::ConflictError,
          Phronomy::Persistence::NotFoundError,
          Phronomy::Persistence::SerializationError,
          ArgumentError,
          Phronomy::ConfigurationError
          release_construction!(key, token)
          raise
        rescue
          # A generic backend/transport failure can be an indeterminate commit.
          # Do not make the same identity creatable again until recovery proves
          # which durable lineage exists.
          fail_construction_closed!(key, token)
          raise
        end

        publish_constructed!(
          key,
          token,
          agent,
          expected_class,
          fail_closed: true
        )
      end

      def load(agent_id, expected_class:, scope_owner: nil)
        key = normalize_agent_id(agent_id)
        token = nil

        loop do
          existing = @mutex.synchronize do
            ensure_running!
            entry = @entries[key]
            if scope_owner && entry && !@scope_owners[key].equal?(scope_owner)
              raise Phronomy::AgentBusyError, "Agent #{key.inspect} belongs to another live owner"
            end
            case entry&.state
            when :live
              entry.agent
            when :unloading
              raise Phronomy::AgentBusyError, "Agent #{key.inspect} is unloading"
            when :constructing, :purging
              @condition.wait(@mutex)
              :retry
            when :recovery_required
              raise ownership_recovery_error(key)
            when nil
              token = Object.new.freeze
              @entries[key] = Entry.new(state: :constructing, agent: nil, token: token)
              @scope_owners[key] = scope_owner if scope_owner
              nil
            # :nocov:
            else
              raise Phronomy::Error,
                "unknown Agent ownership state for #{key.inspect}: #{entry.state.inspect}"
              # :cover:
            end
          end

          next if existing == :retry
          return validate_expected_class!(existing, expected_class, key) if existing
          break
        end

        begin
          agent = yield(@environment)
          publish_constructed!(
            key,
            token,
            agent,
            expected_class,
            fail_closed: false
          )
        rescue
          # Hydration is read-only. A failed load does not establish a new
          # durable Agent lineage, so the reservation can safely be released.
          release_construction!(key, token)
          raise
        end
      end

      def get(agent_id, expected_class:)
        key = normalize_agent_id(agent_id)
        agent = @mutex.synchronize do
          entry = @entries[key]
          case entry&.state
          when :live
            entry.agent
          when :recovery_required
            raise ownership_recovery_error(key)
          # :nocov:
          when :purging, :unloading
            raise Phronomy::AgentBusyError, "Agent #{key.inspect} is #{entry.state}"
            # :cover:
          end
        end
        return nil unless agent

        validate_expected_class!(agent, expected_class, key)
      end

      # Admission and lifetime transitions share this mutex. No Runtime or Store
      # operation is called while it is held.
      def acquire_operation(agent, read_only: false)
        token = Object.new.freeze
        @mutex.synchronize do
          ensure_running! unless read_only && @state == :draining
          entry = @entries[agent.agent_id]
          if entry&.agent&.equal?(agent) && entry.state == :unloading
            raise Phronomy::AgentBusyError, "Agent #{agent.agent_id.inspect} is unloading"
          end
          unless entry&.state == :live && entry.agent.equal?(agent)
            raise Phronomy::RuntimeShutdownError, "Agent is no longer the live Runtime owner"
          end
          (@operations[agent] ||= {})[token] = true
        end
        OperationLease.new(self, agent, token)
      end

      def release_operation(agent, token)
        @mutex.synchronize do
          operations = @operations[agent]
          operations&.delete(token)
          @operations.delete(agent) if operations && operations.empty?
          @condition.broadcast
        end
        true
      end

      # Transfer only the single outstanding hosting operation, atomically with
      # the same admission gate used by all other Agent operations.
      def reserve_approval_detach!(agent, operation_token, transition, parent: nil)
        @mutex.synchronize do
          ensure_running!
          entry = @entries[agent.agent_id]
          operations = @operations[agent]
          unless entry&.state == :live && entry.agent.equal?(agent) && !@scope_owners[agent.agent_id] &&
              operations&.size == 1 && operations.key?(operation_token)
            raise Phronomy::AgentBusyError, "Agent has another owner or accepted operation"
          end
          if parent
            entry = @entries[parent.agent_id]
            unless entry&.state == :live && entry.agent.equal?(parent) && !@scope_owners[parent.agent_id]
              raise Phronomy::AgentBusyError, "Hosted parent no longer owns the local Agent"
            end
            assert_no_operations!(parent)
            @entries[parent.agent_id] = Entry.new(state: :unloading, agent: parent, token: transition)
          end
          @entries[agent.agent_id] = Entry.new(state: :unloading, agent: agent, token: transition)
        end
      end

      # Returns the already accepted transition for duplicate callers.
      def reserve_unload(agent)
        @mutex.synchronize do
          ensure_running!
          entry = @entries[agent.agent_id]
          if entry&.state == :unloading && entry.agent.equal?(agent)
            unless entry.token.is_a?(UnloadTransition)
              raise Phronomy::AgentBusyError, "Agent has a coordinated release in progress"
            end
            return [entry.token, false]
          end
          unless entry&.state == :live && entry.agent.equal?(agent)
            raise Phronomy::RuntimeShutdownError, "Agent is no longer the live Runtime owner"
          end
          assert_no_operations!(agent)
          transition = UnloadTransition.new(agent: agent, environment: @environment, ownership: self)
          @entries[agent.agent_id] = Entry.new(state: :unloading, agent: agent, token: transition)
          [transition, true]
        end
      end

      def finish_unload(agent, transition, success:, parent: nil)
        owners = {agent.agent_id => agent}
        owners[parent.agent_id] = parent if parent
        finish_unload_entries(owners, transition, success: success)
      end

      # Reserve the peer identity even when no instance is loaded. Its absence
      # is then stable until the caller's durable checks commit or roll back.
      def unload_idle_pair(parent, peer_id)
        raise Phronomy::AgentBusyError, "Expected distinct Agent identities" if parent.agent_id == peer_id
        transition = Object.new.freeze
        # A host thread may exit during verification. Keep the short two-owner
        # registry changes indivisible even in the presence of an async interrupt.
        Thread.handle_interrupt(Object => :never) do
          owners = reserve_idle_pair!(parent, peer_id, transition)
          begin
            Thread.handle_interrupt(Object => :immediate) { yield owners[peer_id] }
            success = true
          ensure
            finish_unload_entries(owners, transition, success: success)
          end
        end
      end

      def owned?(agent)
        return false unless agent

        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          entry = @entries[key]
          %i[live unloading].include?(entry&.state) && entry.agent.equal?(agent)
        end
      rescue ArgumentError
        false
      end

      # Moves an exact live owner into :purging before any durable deletion.
      # The returned opaque token must be supplied to complete/abort.
      def begin_purge(agent)
        key = normalize_agent_id(agent.agent_id)
        token = Object.new.freeze

        @mutex.synchronize do
          ensure_running!
          entry = @entries[key]
          unless entry&.state == :live && entry.agent.equal?(agent)
            if entry&.state == :unloading && entry.agent.equal?(agent)
              raise Phronomy::AgentBusyError, "Agent #{key.inspect} is unloading"
            end
            raise Phronomy::RuntimeShutdownError,
              "Agent #{key.inspect} is not the live owner in this Runtime"
          end
          assert_no_operations!(agent)
          @entries[key] = Entry.new(state: :purging, agent: agent, token: token)
        end
        agent.send(:__mark_purging!, @environment)
        token
      end

      def complete_purge(agent, token)
        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          entry = @entries[key]
          validate_purge_entry!(entry, agent, token, key)
          agent.send(:__mark_purged!, @environment)
          @entries.delete(key)
          @scope_owners.delete(key)
          @condition.broadcast
        end
        true
      end

      # Use only when the durable purge is known not to have committed.
      def abort_purge(agent, token)
        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          entry = @entries[key]
          validate_purge_entry!(entry, agent, token, key)
          agent.send(:__restore_live_after_purge_abort!, @environment)
          @entries[key] = Entry.new(state: :live, agent: agent, token: nil)
          @condition.broadcast
        end
        true
      end

      # Unknown durable outcome is fail-closed, but it must not leave load/shutdown
      # waiters blocked forever. Convert the transition into an explicit stable
      # recovery-required state and wake all waiters.
      def leave_purge_uncertain(agent, token)
        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          validate_purge_entry!(@entries[key], agent, token, key)
          agent.send(:__mark_ownership_recovery_required!, @environment)
          @entries[key] = Entry.new(
            state: :recovery_required,
            agent: agent,
            token: nil
          )
          @condition.broadcast
        end
        true
      end

      def begin_draining
        @mutex.synchronize do
          @state = :draining if @state == :running
          @condition.broadcast
        end
        self
      end

      # Live/recovery-required entries do not prevent Runtime shutdown. Only an
      # ownership transition that is still actively changing state must settle.
      def wait_until_idle(deadline)
        @mutex.synchronize do
          while @entries.values.any? { |entry| %i[constructing purging unloading].include?(entry.state) }
            remaining = deadline - monotonic_now
            # :nocov:
            return false if remaining <= 0
            # :cover:
            @condition.wait(@mutex, remaining)
          end
          true
        end
      end

      def after_runtime_shutdown
        agents = @mutex.synchronize do
          @state = :terminated
          owned = @entries.values.filter_map(&:agent).uniq
          @entries.clear
          @scope_owners.clear
          @operations.clear
          @condition.broadcast
          owned
        end
        agents.each { |agent| agent.send(:__release_runtime_owner!, @environment) }
        true
      end

      private

      def reserve_idle_pair!(parent, peer_id, transition)
        @mutex.synchronize do
          ensure_running!
          owners = {parent.agent_id => parent, peer_id => @entries[peer_id]&.agent}
          owners.each do |id, agent|
            entry = @entries[id]
            raise Phronomy::AgentBusyError, "Agent belongs to a scope" if @scope_owners[id]
            next if entry.nil? && agent.nil?
            unless entry&.state == :live && entry.agent.equal?(agent)
              raise Phronomy::AgentBusyError, "Local Agent owner changed"
            end
            assert_no_operations!(agent)
          end
          owners.each { |id, agent| @entries[id] = Entry.new(state: :unloading, agent: agent, token: transition) }
          owners
        end
      end

      def finish_unload_entries(owners, transition, success:)
        @mutex.synchronize do
          owners.each do |id, owner|
            entry = @entries[id]
            unless entry&.state == :unloading && entry.agent.equal?(owner) && entry.token.equal?(transition)
              raise Phronomy::RuntimeShutdownError, "Agent unload reservation is no longer authoritative"
            end
          end
          owners.each do |id, owner|
            if success || owner.nil?
              owner&.send(:__mark_unloaded!)
              @entries.delete(id)
              @scope_owners.delete(id)
            else
              @entries[id] = Entry.new(state: :live, agent: owner, token: nil)
            end
          end
          @condition.broadcast
        end
        true
      end

      def reserve_create!(key, scope_owner: nil)
        token = Object.new.freeze
        @mutex.synchronize do
          ensure_running!
          if (entry = @entries[key])
            raise ownership_recovery_error(key) if entry.state == :recovery_required

            if scope_owner
              raise Phronomy::AgentBusyError, "Agent #{key.inspect} already has a Runtime owner"
            end

            raise Phronomy::AgentAlreadyExistsError,
              "Agent #{key.inspect} already exists in this Runtime (#{entry.state})"
          end
          @entries[key] = Entry.new(state: :constructing, agent: nil, token: token)
          @scope_owners[key] = scope_owner if scope_owner
        end
        token
      end

      def publish_constructed!(key, token, agent, expected_class, fail_closed:)
        validate_expected_class!(agent, expected_class, key)
        unless agent.agent_id.to_s == key
          raise Phronomy::Error,
            "constructed Agent identity mismatch: reserved #{key.inspect}, got #{agent.agent_id.inspect}"
        end

        agent.send(:__bind_runtime_owner!, @environment)
        @mutex.synchronize do
          entry = @entries[key]
          unless entry&.state == :constructing && entry.token.equal?(token)
            raise Phronomy::Error,
              "Agent ownership reservation for #{key.inspect} was lost during construction"
          end
          @entries[key] = Entry.new(state: :live, agent: agent, token: nil)
          @condition.broadcast
        end
        agent
      rescue
        # :nocov:
        if fail_closed
          fail_construction_closed!(key, token, agent: agent)
          agent&.send(:__mark_ownership_recovery_required!, @environment)
        else
          release_construction!(key, token)
        end
        # :cover:
        raise
      end

      def release_construction!(key, token)
        @mutex.synchronize do
          entry = @entries[key]
          # :nocov:
          if entry&.state == :constructing && entry.token.equal?(token)
            @entries.delete(key)
            @scope_owners.delete(key)
            @condition.broadcast
          end
          # :cover:
        end
      end

      def fail_construction_closed!(key, token, agent: nil)
        @mutex.synchronize do
          entry = @entries[key]
          # :nocov:
          return unless entry&.state == :constructing && entry.token.equal?(token)
          # :cover:

          @entries[key] = Entry.new(
            state: :recovery_required,
            agent: agent,
            token: nil
          )
          @condition.broadcast
        end
      end

      def validate_expected_class!(agent, expected_class, key)
        return agent if agent.is_a?(expected_class)

        raise Phronomy::ConfigurationError,
          "Agent definition mismatch: #{key.inspect} is already live as #{agent.class}, not #{expected_class}"
      end

      def validate_purge_entry!(entry, agent, token, key)
        return if entry&.state == :purging &&
          entry.agent.equal?(agent) && entry.token.equal?(token)

        # :nocov:
        raise Phronomy::Error,
          "Agent purge ownership for #{key.inspect} is no longer authoritative"
        # :cover:
      end

      def ownership_recovery_error(key)
        Phronomy::Error.new(
          "Agent #{key.inspect} ownership requires durable recovery/reconciliation"
        )
      end

      def normalize_agent_id(agent_id)
        key = agent_id.to_s
        # :nocov:
        raise ArgumentError, "agent_id must not be empty" if key.empty?
        # :cover:
        key.freeze
      end

      def ensure_running!
        return if @state == :running

        # :nocov:
        raise Phronomy::RuntimeShutdownError,
          "Runtime is #{@state}; Agent ownership changes are not accepted"
        # :cover:
      end

      def assert_no_operations!(agent)
        return unless @operations[agent]&.any?

        raise Phronomy::AgentBusyError, "Agent #{agent.agent_id.inspect} still has accepted operations"
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
