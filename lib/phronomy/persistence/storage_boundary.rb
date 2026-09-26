# frozen_string_literal: true

module Phronomy
  class Persistence
    # Translate only the backend's existing known failure categories. Unknown
    # transport/commit outcomes, TransactionError and application exceptions pass
    # through unchanged so the operation's existing reconciliation stays in charge.
    # @api private
    module StorageBoundary
      def self.call
        yield
      rescue Phronomy::Storage::ConflictError => error
        raise_domain_error(ConflictError, error)
      rescue Phronomy::Storage::NotFoundError => error
        raise_domain_error(NotFoundError, error)
      rescue Phronomy::Storage::SerializationError => error
        raise_domain_error(SerializationError, error)
      rescue Phronomy::Storage::UnsupportedBackendError => error
        raise_domain_error(UnsupportedBackendError, error)
      end

      def self.raise_domain_error(type, original)
        mapped = type.new(original.message)
        mapped.set_backtrace(original.backtrace)
        raise mapped, cause: original
      end
      private_class_method :raise_domain_error
    end
  end
end
