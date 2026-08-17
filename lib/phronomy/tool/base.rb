# frozen_string_literal: true

module Phronomy
  module Tool
    # Public authoring façade for Phronomy Tools.
    #
    # This constant intentionally refers to the exact same Class object as
    # {Phronomy::Agent::Context::Capability::Base}. The implementation namespace
    # remains canonical internally so the existing Tool DSL state, inheritance,
    # built-in Tools, and compatibility surface are not duplicated.
    #
    # @api public
    Base = Phronomy::Agent::Context::Capability::Base
  end
end
