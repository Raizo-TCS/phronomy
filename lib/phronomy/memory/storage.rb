# frozen_string_literal: true

module Phronomy
  module Memory
    # Storage is the persistence axis of conversation management.
    # Implementations are responsible only for saving and loading raw message arrays.
    # Token budgeting, retrieval selection, and compression are handled by other axes.
    module Storage
    end
  end
end
