# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class HandoffCapabilityFactory
      Binding = Data.define(:handoff, :tool_class, :tool_name) do
        def source_agent_id = handoff.source_agent.agent_id

        def request(arguments:, llm_call_id:, tool_call_id:)
          args = arguments.transform_keys(&:to_sym)
          allowed = [:responsibility] + handoff.policy.selectable_categories.map { |category| :"include_#{category}" }
          raise ArgumentError, "Unknown Handoff argument" unless (args.keys - allowed).empty?
          selection = HandoffPolicy::CATEGORIES.to_h do |category|
            value = if handoff.policy.selectable?(category)
              args.fetch(:"include_#{category}") { handoff.policy.default_include?(category) }
            else
              handoff.policy.required?(category)
            end
            [category, value]
          end
          Phronomy::Agent::ControlRequest.new(target_agent_id: handoff.target_agent.agent_id,
            responsibility: args.fetch(:responsibility), selection: selection,
            llm_call_id: llm_call_id, tool_call_id: tool_call_id)
        end

        def initialize(handoff:, tool_class:, tool_name:)
          super(handoff: handoff, tool_class: tool_class, tool_name: tool_name.to_s.freeze)
          freeze
        end
      end

      def self.build(handoff)
        key = handoff.send(:transport_key)
        tool_name = "phronomy_handoff_#{key}"
        description = handoff.description
        policy = handoff.policy

        klass = Class.new(Phronomy::Tool::Base) do
          self.tool_name(tool_name)
          self.description(description)
          execution_mode :cooperative
          param :responsibility,
            type: :string,
            required: true,
            desc: "The concrete responsibility the target Agent must continue."

          policy.selectable_categories.each do |category|
            param :"include_#{category}",
              type: :boolean,
              required: false,
              desc: "Whether to transfer selectable #{category} Context."
          end

          define_method(:execute) do |**_args|
            raise Phronomy::HandoffError,
              "Handoff capabilities are control-plane operations and must not execute as Tools"
          end
        end

        Binding.new(handoff: handoff, tool_class: klass, tool_name: tool_name)
      end
    end
  end
end
