# frozen_string_literal: true

module Phronomy
  module Agent
    module Selection
      CONSTRAINT_MODES = %i[required selectable forbidden].freeze

      Constraint = Data.define(:mode, :origin, :reason) do
        def initialize(mode:, origin:, reason: nil)
          normalized_mode = mode.to_sym
          unless CONSTRAINT_MODES.include?(normalized_mode)
            raise ArgumentError, "unknown Selection constraint mode: #{mode.inspect}"
          end

          super(
            mode: normalized_mode,
            origin: origin.to_sym,
            reason: reason&.to_s&.freeze
          )
          freeze
        end

        def required?
          mode == :required
        end

        def selectable?
          mode == :selectable
        end

        def forbidden?
          mode == :forbidden
        end

        def self.required(origin:, reason: nil)
          new(mode: :required, origin: origin, reason: reason)
        end

        def self.selectable(origin:, reason: nil)
          new(mode: :selectable, origin: origin, reason: reason)
        end

        def self.forbidden(origin:, reason: nil)
          new(mode: :forbidden, origin: origin, reason: reason)
        end
      end
    end
  end
end
