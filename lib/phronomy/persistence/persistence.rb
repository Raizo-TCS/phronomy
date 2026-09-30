# frozen_string_literal: true

module Phronomy
  # Domain-neutral transaction ownership and participation. Domain operations
  # choose their atomic boundary; composition supplies their storage adapters.
  # @api public
  class Persistence
    attr_reader :backend

    def initialize(backend:)
      StorageBoundary.call { Storage::Backend.validate_capabilities!(backend) }
      @backend = backend
    end

    # Bind an injected adapter for ordinary synchronous reads/standalone writes.
    # Only that adapter receives Storage's raw view. Multi-operation changes use
    # atomic/Transaction#participate so all participants use the exact same view.
    # @api private
    def bind(adapter)
      StorageBoundary.call { adapter.new(backend.view) }
    end
  end
end
