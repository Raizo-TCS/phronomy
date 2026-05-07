# frozen_string_literal: true

module Phronomy
  module ActiveRecord
    # DSL mixin that can be included in ApplicationRecord subclasses
    # to declaratively associate them with Phronomy persistence roles.
    #
    # @example
    #   class PhronomyMessage < ApplicationRecord
    #     acts_as_phronomy_message
    #   end
    module ActsAs
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Configures this model as a Phronomy message store.
        # Applies validations and exposes a convenience factory method.
        #
        # @return [Phronomy::Memory::ActiveRecordMemory] a ready-to-use memory object
        def acts_as_phronomy_message
          include ::Phronomy::ActiveRecord::Message

          define_singleton_method(:phronomy_memory) do
            ::Phronomy::Memory::ActiveRecordMemory.new(model_class: self)
          end
        end
      end
    end
  end
end
