# frozen_string_literal: true

# This convenience API owns a fresh ephemeral Persistence and a scoped Agent.
# The application entry loads the method definition; Agent execution does not
# delegate to or require this higher-level composition implementation.
module Phronomy
  module Agent
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

      open_scope do |scope|
        persistence = Phronomy::PersistenceComposition.agent
        agent = scope.create(definition,
          context: context,
          knowledge: knowledge,
          persistence: persistence,
          on_event: on_event,
          &event_block)
        agent.invoke(input, **invoke_options)
      end
    end
  end
end
