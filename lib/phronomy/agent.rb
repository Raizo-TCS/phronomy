# frozen_string_literal: true

module Phronomy
  module Agent
    StreamEvent = Data.define(:type, :payload)

    def self.run_once(
      definition:,
      input:,
      context: nil,
      knowledge: [],
      on_event: nil,
      **invoke_options,
      &event_block
    )
      if on_event && event_block
        raise ArgumentError, "Provide either on_event: or a block, not both"
      end

      persistence = Phronomy::Persistence::InMemory.new
      agent = definition.create(
        context: context,
        knowledge: knowledge,
        persistence: persistence,
        on_event: on_event,
        &event_block
      )
      agent.invoke(input, **invoke_options)
    end
  end
end

require_relative "agent/async_event_api"

unless Phronomy::Agent::Base < Phronomy::Agent::AsyncEventApi
  Phronomy::Agent::Base.prepend(Phronomy::Agent::AsyncEventApi)
end

# ACS-15 Recovery / CG-09 public event API clean break.
require_relative "agent/acs15_recovery"
