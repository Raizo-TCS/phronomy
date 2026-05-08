# frozen_string_literal: true

module Phronomy
  module Memory
    # Retrieval is the selection axis of conversation management.
    # Implementations decide which messages from a full history to return
    # given a query and a maximum message count or token limit.
    # Token budgeting is NOT their responsibility — that belongs to Context::Assembler.
    module Retrieval
    end
  end
end
