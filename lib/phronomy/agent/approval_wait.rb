# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable reference to one committed standalone approval boundary.
    ApprovalWait = Data.define(:execution_id, :approval_request_id, :execution_revision)
  end
end
