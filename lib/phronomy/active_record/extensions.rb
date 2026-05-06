# frozen_string_literal: true

module Phronomy
  module ActiveRecord
    # Convenience namespace loaded by Railtie when ActiveRecord is available.
    # Ensures all Phronomy::ActiveRecord mixins are eager-loaded in Rails context.
    module Extensions
    end
  end
end

require_relative "checkpoint"
require_relative "message"
require_relative "acts_as"
