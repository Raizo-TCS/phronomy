# frozen_string_literal: true

module Phronomy
  module Agent
    StreamEvent = Data.define(:type, :payload)

    # Own Agents acquired by the block, then attempt every release. A returned
    # TaskResult is awaited and unwrapped; a plain value is returned unchanged.
    # @yield [scope] the Runtime-bound owner of newly materialized Agents
    # @yieldparam scope [Phronomy::Agent::Scope]
    # @return [Object] the block value or resolved TaskResult value
    # @raise [ScopeCleanupError] successful work whose Agent release failed
    # @api public
    def self.open_scope(&block)
      Scope.send(:open, &block)
    end
  end
end

require_relative "../async_event_api"

unless Phronomy::Agent::Base < Phronomy::Agent::AsyncEventApi
  Phronomy::Agent::Base.prepend(Phronomy::Agent::AsyncEventApi)
end

# Durable Agent Recovery and Agent-incarnation event binding.
require_relative "../recovery/recovery_support"
require_relative "../recovery/recovery_coordinator"

Phronomy::Agent::Base.prepend(Phronomy::Agent::LifetimeApi)
