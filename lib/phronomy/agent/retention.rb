# frozen_string_literal: true

module Phronomy
  module Agent
    # A durable reference prevents whole-Agent purge. The referencing domain
    # decides when its opaque owner key can be released.
    # @api public
    Retention = Data.define(:agent_id, :execution_id, :owner_key) do
      def initialize(agent_id:, owner_key:, execution_id: nil)
        raise ArgumentError, "retention identities must not be empty" if agent_id.to_s.empty? || owner_key.to_s.empty?
        super(agent_id: agent_id.to_s.freeze, execution_id: execution_id&.to_s&.freeze, owner_key: owner_key.to_s.freeze)
      end

      def to_h = {"agent_id" => agent_id, "execution_id" => execution_id, "owner_key" => owner_key}.freeze
    end
  end
end
