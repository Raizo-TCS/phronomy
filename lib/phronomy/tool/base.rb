# frozen_string_literal: true

module Phronomy
  module Tool
    # Base class extending RubyLLM::Tool with Phronomy-specific DSL (scope/on_error/requires_approval).
    #
    # @example
    #   class SearchKnowledgeBase < Phronomy::Tool::Base
    #     description "Search the internal knowledge base"
    #     param :query, type: :string, desc: "Search query"
    #     scope :read_only
    #     on_error :return_empty
    #
    #     def execute(query:)
    #       KnowledgeBase.search(query)
    #     end
    #   end
    class Base < RubyLLM::Tool
      class << self
        # Sets the access scope for this tool (metadata; enforcement is the responsibility of
        # the Graph/Guardrail layer).
        # @param value [Symbol] e.g. :read_only, :write, :admin
        def scope(value = nil)
          return @scope if value.nil?

          @scope = value
        end

        # Configures error-handling behavior.
        # @param behavior [Symbol] :raise (default) or :return_empty
        def on_error(behavior = nil)
          return @on_error || :raise if behavior.nil?

          @on_error = behavior
        end

        # Configures whether human approval is required before executing this tool.
        # @param value [Boolean]
        def requires_approval(value = nil)
          return @requires_approval || false if value.nil?

          @requires_approval = value
        end
      end

      # Overrides RubyLLM::Tool#call to apply the on_error policy and wrap errors as ToolError.
      def call(args)
        super
      rescue => e
        case self.class.on_error
        when :return_empty
          []
        else
          raise Phronomy::ToolError, "#{self.class.name} execution failed: #{e.message}"
        end
      end

      # Instance method for requires_approval? (convenience accessor).
      def requires_approval?
        self.class.requires_approval
      end
    end
  end
end
