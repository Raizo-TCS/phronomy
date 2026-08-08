# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextPolicyRegistry
      class << self
        def default
          @default ||= new.tap do |registry|
            registry.register(id: "default-recent-v1", version: 1) do |config|
              ContextPolicies::Default.new(config)
            end
          end
        end
      end

      def initialize
        @factories = {}
        @mutex = Mutex.new
      end

      def register(id:, version:, &factory)
        raise ArgumentError, "Context Policy factory is required" unless factory

        key = [id.to_s, Integer(version)].freeze
        @mutex.synchronize do
          raise ArgumentError, "Context Policy already registered: #{key.join("@")}" if @factories.key?(key)
          @factories[key] = factory
        end
        self
      end

      def resolve(descriptor)
        key = [descriptor.id.to_s, Integer(descriptor.version)]
        factory = @mutex.synchronize { @factories[key] }
        raise Phronomy::ConfigurationError, "Unknown Context Policy: #{key.join("@")}" unless factory

        policy = factory.call(descriptor.config)
        unless policy.is_a?(ContextPolicy)
          raise Phronomy::ConfigurationError,
            "Context Policy factory returned #{policy.class}, expected #{ContextPolicy}"
        end
        policy
      end
    end
  end
end
