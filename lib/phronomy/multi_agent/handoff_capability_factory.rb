# frozen_string_literal: true

require "weakref"

module Phronomy
  module MultiAgent
    class HandoffCapabilityFactory
      REGISTRY_MUTEX = Mutex.new
      private_constant :REGISTRY_MUTEX

      Binding = Data.define(:handoff, :tool_class, :tool_name) do
        def initialize(handoff:, tool_class:, tool_name:)
          super(handoff: handoff, tool_class: tool_class, tool_name: tool_name.to_s.freeze)
          freeze
        end
      end

      def self.build(handoff)
        key = handoff.send(:transport_key)
        source_name = class_slug(handoff.source_agent.class)
        target_name = class_slug(handoff.target_agent.class)
        tool_name = "phronomy_handoff_#{source_name}_to_#{target_name}_#{key}"
        description = handoff.description
        policy = handoff.policy

        klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
          self.tool_name(tool_name)
          self.description(description)
          execution_mode :cooperative
          param :responsibility,
            type: :string,
            required: true,
            desc: "The concrete responsibility the target Agent must continue."

          policy.selectable_categories.each do |category|
            param "include_#{category}".to_sym,
              type: :boolean,
              required: false,
              desc: "Whether to transfer selectable #{category} Context."
          end

          define_method(:execute) do |**_args|
            raise Phronomy::HandoffError,
              "Handoff capabilities are control-plane operations and must not execute as Tools"
          end
        end

        binding = Binding.new(handoff: handoff, tool_class: klass, tool_name: tool_name)
        registry_mutex.synchronize { registry[tool_name] = WeakRef.new(binding) }
        binding
      end

      def self.lookup(tool_name)
        key = tool_name.to_s
        registry_mutex.synchronize do
          reference = registry[key]
          return nil unless reference

          begin
            reference.__getobj__
          rescue WeakRef::RefError
            registry.delete(key)
            nil
          end
        end
      end

      def self.registry
        @registry ||= {}
      end
      private_class_method :registry

      def self.registry_mutex
        REGISTRY_MUTEX
      end
      private_class_method :registry_mutex

      def self.class_slug(klass)
        raw = (klass.name || "agent").gsub("::", "_")
        raw.gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
          .gsub(/[^a-zA-Z0-9_]/, "_")
          .downcase
      end
      private_class_method :class_slug
    end
  end
end
