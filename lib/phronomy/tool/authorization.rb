# frozen_string_literal: true

module Phronomy
  module Tool
    # Common authorization framework. Requests implement the Tool request protocol;
    # callers attach their own immutable identity context, never a live owner.
    module Authorization
      VALID_DECISIONS = %i[allow require_approval reject].freeze
      Decision = Data.define(:decision, :facts, :reason)

      def self.call(request:, arguments:, context:, facts: nil, requirement: false, policy: nil)
        value = facts&.call(arguments, context)
        unless value.nil? || value.is_a?(Hash)
          raise Phronomy::ConfigurationError, "approval_facts must return a Hash or nil (got #{value.class})"
        end
        value = snapshot(value || {})
        request = request.with(facts: value)
        required = requirement.respond_to?(:call) ? requirement.call(request) : requirement
        default = case required
        when true then :require_approval
        when false, nil then :allow
        else
          raise Phronomy::ConfigurationError,
            "requires_approval callable must return true or false (got #{required.inspect})"
        end
        request = request.with(default_decision: default)
        decision = policy ? policy.call(request) : default
        decision = decision.to_sym if decision.respond_to?(:to_sym)
        unless VALID_DECISIONS.include?(decision)
          raise Phronomy::ConfigurationError,
            "tool_approval_policy must return :allow, :require_approval, or :reject (got #{decision.inspect})"
        end
        reason = if decision == :require_approval
          (request.origin == :mcp) ? "MCP Tool execution requires approval" : "Tool execution requires approval"
        end
        Decision.new(decision: decision, facts: value, reason: reason)
      end

      def self.snapshot(value)
        if phronomy_managed_live_domain_object?(value)
          raise Phronomy::ConfigurationError,
            "authorization worker snapshot cannot contain Phronomy-managed live " \
            "domain object #{value.class}"
        end

        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[snapshot(key)] = snapshot(item)
          end.freeze
        when Array
          value.map { |item| snapshot(item) }.freeze
        when String
          value.dup.freeze
        else
          # Application-defined opaque objects are permitted by ACS-11 and remain
          # Application-owned. A stricter general value-type protocol is deferred.
          value
        end
      end

      def self.phronomy_managed_live_domain_object?(value)
        value.is_a?(Phronomy::Concurrency::WorkerInputRestricted)
      end
      private_class_method :phronomy_managed_live_domain_object?

      def self.behavior(value, name)
        return value if value.nil? || value == true || value == false
        if phronomy_managed_live_domain_object?(value)
          raise Phronomy::ConfigurationError,
            "#{name} must not be a Phronomy-managed live domain object (got #{value.class})"
        end
        value
      end
    end
  end
end
