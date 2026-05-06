# frozen_string_literal: true

module Phronomy
  module ActiveRecord
    # Mixin for models backed by the phronomy_checkpoints table.
    #
    # @example
    #   class PhronomyCheckpoint < ApplicationRecord
    #     include Phronomy::ActiveRecord::Checkpoint
    #   end
    module Checkpoint
      def self.included(base)
        base.validates :thread_id, presence: true
        base.validates :state_json, presence: true
      end
    end
  end
end
