# frozen_string_literal: true

module Phronomy
  class Runtime
    # Runtime-local Team identity and construction exclusion; no execution state.
    # @api private
    class TeamOwnershipRegistry
      def initialize
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @owners = {}
        @constructing = {}
        @draining = false
      end

      def fetch(id, klass:, create:, persistence:)
        @mutex.synchronize do
          loop do
            raise Phronomy::RuntimeShutdownError, "Runtime is draining" if @draining
            if (owner = @owners[id])
              raise Phronomy::Persistence::ConflictError, "Team #{id} already exists" if create
              unless owner.is_a?(klass) && owner.persistence.equal?(persistence)
                raise Phronomy::ConfigurationError, "Team #{id} owner or Persistence mismatch"
              end
              return owner
            end
            break unless @constructing[id]
            @condition.wait(@mutex)
          end
          @constructing[id] = true
        end
        begin
          owner = yield
          @mutex.synchronize { @owners[id] = owner }
          owner
        ensure
          @mutex.synchronize do
            @constructing.delete(id)
            @condition.broadcast
          end
        end
      end

      def get(id, klass:)
        @mutex.synchronize do
          owner = @owners[id]
          if owner && !owner.is_a?(klass)
            raise Phronomy::ConfigurationError, "Team #{id} definition mismatch"
          end
          owner
        end
      end

      def begin_draining
        @mutex.synchronize do
          @draining = true
          @condition.broadcast
        end
      end

      def wait_until_stable(deadline)
        @mutex.synchronize do
          until @constructing.empty?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if remaining <= 0
            @condition.wait(@mutex, remaining)
          end
          true
        end
      end

      def shutdown!
        @mutex.synchronize { @owners.clear }
      end
    end
  end
end
