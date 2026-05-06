# frozen_string_literal: true

module Phronomy
  module ActiveRecord
    # Mixin for models backed by the phronomy_messages table.
    #
    # @example
    #   class PhronomyMessage < ApplicationRecord
    #     include Phronomy::ActiveRecord::Message
    #   end
    module Message
      def self.included(base)
        base.validates :thread_id, presence: true
        base.validates :role, presence: true
        # content may be blank for assistant messages that carry only tool calls
        base.validates :content, presence: false, allow_nil: true
      end
    end
  end
end
