# frozen_string_literal: true

module Phronomy
  module Storage
    # Root handles route to the current scope; bound handles cannot outlive it.
    # @api public
    class View
      def initialize(backend, scope: nil, context: nil)
        @backend, @scope, @context = backend, scope, context
        @handles = {}
      end

      # @api public
      def records(resource) = handle(resource, :records, Records)
      # @api public
      def streams(resource) = handle(resource, :streams, Streams)
      # @api public
      def blobs(resource) = handle(resource, :blobs, Blobs)

      # Acquire stable anchors before evaluating conditions in the same view.
      # @api public
      def check!(guards:, conditions:)
        validate!
        raise ArgumentError, "guards and conditions must be arrays" unless guards.is_a?(Array) && conditions.is_a?(Array)
        guards.each do |guard|
          raise ArgumentError, "expected GuardRef" unless guard.is_a?(GuardRef)
          resolve(guard.resource, :records)
        end
        conditions.each do |condition|
          case condition
          when Condition::RevisionIs then resolve(condition.resource, :records)
          when Condition::StreamHeadIs then resolve(condition.resource, :streams)
          when Condition::NoRows then resolve(condition.resource, :records).index_values(condition.index, condition.equals)
          else raise ArgumentError, "unsupported condition"
          end
          require_guard!(condition, guards)
        end
        atomic do |bound|
          guards.uniq.sort_by { |g| [resolve(g.resource, :records).id.b, g.key.b] }.each do |guard|
            bound.perform(:lock_guard, resolve(guard.resource, :records), key: guard.key)
          end
          conditions.each do |condition|
            matched = case condition
            when Condition::RevisionIs then bound.records(condition.resource).read(condition.key)&.revision == condition.expected
            when Condition::StreamHeadIs then bound.streams(condition.resource).head(stream: condition.stream) == condition.expected
            when Condition::NoRows then bound.records(condition.resource).scan(index: condition.index, equals: condition.equals, limit: 1).empty?
            end
            raise ConditionFailedError, condition unless matched
          end
          true
        end
      end

      # Keeps domain encoding/response validation inside the physical transaction.
      # @api private
      def atomic
        validate!
        unless @scope
          current = @backend.current_view
          return current.atomic { |bound| yield bound } if current
          return @backend.transaction { |bound| bound.atomic { yield bound } }
        end
        completed = false
        begin
          result = yield self
          @scope.check!
          completed = true
          result
        ensure
          @scope.fail! unless completed
        end
      end

      # @api private
      def perform(operation, resource, **arguments)
        atomic { |bound| bound.dispatch(operation, resource, **arguments) }
      end

      # @api private
      def dispatch(operation, resource, **arguments)
        validate!
        @backend.execute(@context, operation, resource, **arguments)
      end

      # @api private
      def validate!
        @scope&.check!
        true
      end

      private

      def require_guard!(condition, guards)
        resource = @backend.resources.fetch(condition.resource.is_a?(Resource) ? condition.resource.id : condition.resource)
        guard = resource.guard
        return unless guard
        key = case condition
        when Condition::RevisionIs
          if guard[:via] == :key
            condition.key
          else
            raise ArgumentError, "revision checks require a key-based guard"
          end
        when Condition::StreamHeadIs then condition.stream
        when Condition::NoRows
          condition.equals.fetch(guard[:via]) { raise ArgumentError, "condition must constrain its guard attribute" }
        end
        covered = guards.any? do |candidate|
          resolve(candidate.resource, :records).id == guard[:resource] && candidate.key == key
        end
        raise ArgumentError, "condition requires its declared guard" unless covered
      end

      def resolve(resource, kind)
        id = resource.is_a?(Resource) ? resource.id : resource
        registered = @backend.resources[id]
        valid = registered && registered.kind == kind && (!resource.is_a?(Resource) || registered.equal?(resource))
        unless valid
          raise UnsupportedBackendError, "unregistered or mismatched #{kind} resource: #{id}"
        end
        registered
      end

      def handle(resource, kind, type)
        validate!
        registered = resolve(resource, kind)
        @handles[registered.id] ||= type.new(self, registered)
      end
    end
  end
end
