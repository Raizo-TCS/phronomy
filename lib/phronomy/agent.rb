# frozen_string_literal: true

module Phronomy
  module Agent
    StreamEvent = Data.define(:type, :payload)

    def self.run_once(definition:, input:, context: nil, knowledge: [], **invoke_options)
      persistence = Phronomy::Persistence::InMemory.new
      agent = definition.create(
        context: context,
        knowledge: knowledge,
        persistence: persistence
      )
      agent.invoke(input, **invoke_options)
    end
  end
end

require_relative "agent/persistence_ownership"
require_relative "agent/async_event_api"

unless Phronomy::Agent::Base < Phronomy::Agent::PersistenceOwnership
  Phronomy::Agent::Base.prepend(Phronomy::Agent::PersistenceOwnership)
end

unless Phronomy::Agent::Base.singleton_class < Phronomy::Agent::PersistenceOwnership::ClassMethods
  Phronomy::Agent::Base.singleton_class.prepend(
    Phronomy::Agent::PersistenceOwnership::ClassMethods
  )
end

unless Phronomy::Agent::Base < Phronomy::Agent::AsyncEventApi
  Phronomy::Agent::Base.prepend(Phronomy::Agent::AsyncEventApi)
end
