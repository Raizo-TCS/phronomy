# frozen_string_literal: true

module Phronomy
  module Agent
    StreamEvent = Data.define(:type, :payload)
  end
end

require_relative "../async_event_api"

unless Phronomy::Agent::Base < Phronomy::Agent::AsyncEventApi
  Phronomy::Agent::Base.prepend(Phronomy::Agent::AsyncEventApi)
end

# Durable Agent Recovery and Agent-incarnation event binding.
require_relative "../recovery_support"
require_relative "../recovery_coordinator"
