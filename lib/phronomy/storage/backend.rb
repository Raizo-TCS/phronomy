# frozen_string_literal: true

module Phronomy
  module Storage
    # Neutral storage SPI. Domain resource declarations are supplied by composition.
    # @api public
    class Backend
      REQUIRED_CAPABILITIES = {spi_version: 2, atomic_resources: true,
                               record_cas: true, stream_cas: true, conditional_unique: true,
                               guarded_checks: true, nested_savepoints: true}.freeze
      attr_reader :resources, :view

      # @api public
      def initialize(resources:)
        unless resources.is_a?(Array) && resources.all? { |resource| resource.is_a?(Resource) }
          raise UnsupportedBackendError, "SPI 2 requires Resource declarations"
        end
        @resources = resources.to_h { |resource| [resource.id, resource] }.freeze
        raise UnsupportedBackendError, "duplicate resource identity" unless @resources.length == resources.length
        @resources.each_value do |resource|
          next unless resource.guard
          anchor = @resources[resource.guard.fetch(:resource)]
          raise UnsupportedBackendError, "guard must name a registered records resource" unless anchor && anchor.kind == :records
        end
        @view = View.new(self)
      end

      # Reject the previous eight-repository SPI before constructing domain wrappers.
      # @api public
      def self.validate_capabilities!(backend)
        capabilities = backend.respond_to?(:capabilities) ? backend.capabilities : {}
        missing = REQUIRED_CAPABILITIES.reject { |key, value| capabilities.is_a?(Hash) && capabilities[key] == value }
        unless missing.empty? && backend.respond_to?(:view) && backend.respond_to?(:transaction)
          raise UnsupportedBackendError, "Persistence requires Storage SPI 2: #{missing.keys.join(", ")}"
        end
      end

      # @api public
      def capabilities
        REQUIRED_CAPABILITIES.transform_values { |value| (value == true) ? false : value }.freeze
      end

      # All declared resources participate in one atomic transaction domain.
      # Record and stream revisions provide compare-and-swap conflict detection.
      # This does not
      # mean cross-process Workflow admission or distributed locking.
      # Storage failures whose commit outcome is fundamentally unknown remain
      # database failures; Phronomy does not claim exactly-once semantics.
      # Explicit nesting uses savepoints. Non-local block exits raise and roll back.
      # @api public
      def transaction
        current_view&.validate!
        storage_transaction do |context|
          scope = Scope.new
          bound = View.new(self, scope: scope, context: context)
          views = stack
          views.push(bound)
          completed = false
          begin
            result = yield bound
            scope.check!
            completed = true
            result
          ensure
            scope.close!
            views.pop
            Thread.current.thread_variable_get(:phronomy_storage_scopes)&.delete(self) if views.empty?
            if !completed && $!.nil?
              raise TransactionError, "transaction block must complete normally; non-local exit rolled back"
            end
          end
        end
      end

      # @api private
      def current_view
        Thread.current.thread_variable_get(:phronomy_storage_scopes)&.dig(self)&.last.tap { |bound| bound&.validate! }
      end

      # @api private
      def execute(context, operation, resource, **arguments)
        send(operation, context, resource, **arguments)
      end

      private

      def stack
        scopes = Thread.current.thread_variable_get(:phronomy_storage_scopes)
        unless scopes
          scopes = {}
          Thread.current.thread_variable_set(:phronomy_storage_scopes, scopes)
        end
        scopes[self] ||= []
      end

      def storage_transaction
        raise UnsupportedBackendError, "backend must implement an atomic storage transaction"
      end
    end
  end
end
