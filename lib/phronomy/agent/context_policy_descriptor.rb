# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    ContextPolicyDescriptor = Data.define(:id, :version, :config) do
      def initialize(id:, version:, config: {})
        normalized_config = Immutable.copy(config || {})
        Immutable.validate_canonical_json!(normalized_config, label: "Context Policy config")
        super(
          id: id.to_s.freeze,
          version: Integer(version),
          config: normalized_config
        )
        raise ArgumentError, "Context Policy id must not be empty" if id.empty?
        raise ArgumentError, "Context Policy version must be positive" unless version.positive?
        freeze
      end

      def self.from_h(hash)
        descriptor = new(
          id: hash.fetch("id") { hash.fetch(:id) },
          version: hash.fetch("version") { hash.fetch(:version) },
          config: hash["config"] || hash[:config] || {}
        )
        expected_digest = hash["config_digest"] || hash[:config_digest]
        if expected_digest && expected_digest.to_s != descriptor.config_digest
          raise Phronomy::ConfigurationError,
            "Context Policy config digest mismatch for #{descriptor.id}@#{descriptor.version}"
        end
        descriptor
      end

      def config_digest
        "sha256:#{Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(config))}"
      end

      def to_h
        {
          "id" => id,
          "version" => version,
          "config" => config,
          "config_digest" => config_digest
        }
      end
    end
  end
end
