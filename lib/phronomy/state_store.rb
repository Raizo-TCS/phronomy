# frozen_string_literal: true

module Phronomy
  # Namespace for state persistence backends.
  # A StateStore saves and loads graph State objects keyed by thread_id.
  # The thread_id is embedded in the State itself (state.thread_id).
  module StateStore
  end
end
