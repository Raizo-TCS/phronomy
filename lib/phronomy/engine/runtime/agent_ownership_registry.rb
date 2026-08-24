# frozen_string_literal: true

module Phronomy
  class Runtime
    # Process-local authoritative owner registry for mutable Agent instances.
    #
    # This is not a cache. While a Runtime is alive, one agent_id maps to at most
    # one mutable live Agent object. Construction is reserved before durable
    # create/load so concurrent callers cannot materialize independent objects.
    class AgentOwnershipRegistry
      Entry = Data.define(:state, :agent, :token)
      private_constant :Entry

      def initialize(runtime:)
        @runtime = runtime
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @entries = {}
        @state = :running
      end

      def create(agent_id, expected_class:)
        key = normalize_agent_id(agent_id)
        token = reserve_create!(key)

        begin
          agent = yield(@runtime)
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

      def load(agent_id, expected_class:)
        key = normalize_agent_id(agent_id)
        token = nil

        loop do
          existing = @mutex.synchronize do
            ensure_running!
            entry = @entries[key]
            case entry&.state
            when :live
              entry.agent
            when :constructing, :purging
              @condition.wait(@mutex)
              :retry
            when :recovery_required
              raise ownership_recovery_error(key)
            when nil
              token = Object.new.freeze
              @entries[key] = Entry.new(state: :constructing, agent: nil, token: token)
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
          agent = yield(@runtime)
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
          when :purging
            raise Phronomy::Error, "Agent #{key.inspect} is being purged"
            # :cover:
          end
        end
        return nil unless agent

        validate_expected_class!(agent, expected_class, key)
      end

      def owned?(agent)
        return false unless agent

        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          entry = @entries[key]
          entry&.state == :live && entry.agent.equal?(agent)
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
            raise Phronomy::RuntimeShutdownError,
              "Agent #{key.inspect} is not the live owner in this Runtime"
          end
          @entries[key] = Entry.new(state: :purging, agent: agent, token: token)
        end
        agent.send(:__mark_purging!, @runtime)
        token
      end

      def complete_purge(agent, token)
        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          entry = @entries[key]
          validate_purge_entry!(entry, agent, token, key)
          @entries.delete(key)
          @condition.broadcast
        end
        agent.send(:__mark_purged!, @runtime)
        true
      end

      # Use only when the durable purge is known not to have committed.
      def abort_purge(agent, token)
        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          entry = @entries[key]
          validate_purge_entry!(entry, agent, token, key)
          @entries[key] = Entry.new(state: :live, agent: agent, token: nil)
          @condition.broadcast
        end
        agent.send(:__restore_live_after_purge_abort!, @runtime)
        true
      end

      # Unknown durable outcome is fail-closed, but it must not leave load/shutdown
      # waiters blocked forever. Convert the transition into an explicit stable
      # recovery-required state and wake all waiters.
      def leave_purge_uncertain(agent, token)
        key = normalize_agent_id(agent.agent_id)
        @mutex.synchronize do
          validate_purge_entry!(@entries[key], agent, token, key)
          @entries[key] = Entry.new(
            state: :recovery_required,
            agent: agent,
            token: nil
          )
          @condition.broadcast
        end
        agent.send(:__mark_ownership_recovery_required!, @runtime)
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
      def wait_until_stable(deadline)
        @mutex.synchronize do
          while @entries.values.any? { |entry| %i[constructing purging].include?(entry.state) }
            remaining = deadline - monotonic_now
            # :nocov:
            return false if remaining <= 0
            # :cover:
            @condition.wait(@mutex, remaining)
          end
          true
        end
      end

      def shutdown!
        agents = @mutex.synchronize do
          @state = :terminated
          owned = @entries.values.filter_map(&:agent).uniq
          @entries.clear
          @condition.broadcast
          owned
        end
        agents.each { |agent| agent.send(:__release_runtime_owner!, @runtime) }
        true
      end

      private

      def reserve_create!(key)
        token = Object.new.freeze
        @mutex.synchronize do
          ensure_running!
          if (entry = @entries[key])
            raise ownership_recovery_error(key) if entry.state == :recovery_required

            raise Phronomy::AgentAlreadyExistsError,
              "Agent #{key.inspect} already exists in this Runtime (#{entry.state})"
          end
          @entries[key] = Entry.new(state: :constructing, agent: nil, token: token)
        end
        token
      end

      def publish_constructed!(key, token, agent, expected_class, fail_closed:)
        validate_expected_class!(agent, expected_class, key)
        unless agent.agent_id.to_s == key
          raise Phronomy::Error,
            "constructed Agent identity mismatch: reserved #{key.inspect}, got #{agent.agent_id.inspect}"
        end

        agent.send(:__bind_runtime_owner!, @runtime)
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
          agent&.send(:__mark_ownership_recovery_required!, @runtime)
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

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
