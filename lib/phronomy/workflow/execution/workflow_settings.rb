# frozen_string_literal: true

module Phronomy
  # Workflow-owned progress limit and optional state repository. Composition
  # supplies these values; existing execution boundaries decide when to read.
  # @api private
  class WorkflowSettings
    class << self
      # Bind at boot without reading settings or starting runtime resources.
      def install_provider(&provider)
        raise ArgumentError, "settings provider requires a block" unless provider
        @provider = provider
        nil
      end

      # Read only when requested; no cache or change notification is involved.
      def current
        @provider.call
      end
    end

    attr_accessor :recursion_limit, :workflow_store

    def initialize(recursion_limit:)
      @recursion_limit = recursion_limit
    end
  end
end
