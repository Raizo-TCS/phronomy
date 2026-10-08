# frozen_string_literal: true

module Phronomy
  module Agent
    # An opaque state reference owned and interpreted by its bound participant.
    # @api public
    ExecutionExtensionState = Data.define(:binding_key, :binding_version, :state_ref) do
      def initialize(binding_key:, binding_version:, state_ref: nil)
        raise ArgumentError, "binding_key is required" if binding_key.to_s.empty?
        raise ArgumentError, "binding_version must be positive" unless binding_version.is_a?(Integer) && binding_version.positive?
        super(binding_key: binding_key.to_s.freeze, binding_version: binding_version, state_ref: state_ref&.to_s&.freeze)
      end

      def to_h
        {"binding_key" => binding_key, "binding_version" => binding_version, "state_ref" => state_ref}.freeze
      end

      def self.from_h(value) = new(**value.transform_keys(&:to_sym))
    end
  end
end
