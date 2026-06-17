# frozen_string_literal: true

# FSMSession has been moved to Phronomy::FSMSession (top-level).
# This file exists only for backward compatibility.
# @deprecated Use Phronomy::FSMSession directly.
module Phronomy
  class Workflow
    FSMSession = Phronomy::FSMSession # rubocop:disable Naming/ConstantName
  end
end
