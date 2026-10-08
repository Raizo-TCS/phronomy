# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module Context
    # Invalid canonical context input; independent of its persistence backend.
    class ManifestError < Phronomy::Error; end
  end
end
