# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Marks framework-managed objects excluded from authorization worker value
    # snapshots and application behavior handles. Each owning type opts in.
    # This methodless contract does not validate arbitrary object graphs or
    # restrict every OffloadPool command. Application-owned opaque values retain
    # their existing contract (ADR-024/045).
    # @api private
    module WorkerInputRestricted
    end
  end
end
