# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Connects domain registries to the generic Runtime shutdown protocol.
    # Construction does not register participants or start worker resources.
    # @api private
    class EngineEnvironment < ExecutionEnvironment
      def initialize(runtime: Phronomy::Runtime.instance)
        @runtime = runtime
      end

      def admissions
        @runtime.__register_shutdown_participant(
          key: AdmissionRegistry, participant: AdmissionRegistry.new
        )
      end

      def ownership
        existing_ownership || @runtime.__register_shutdown_participant(
          key: TeamOwnershipRegistry, participant: TeamOwnershipRegistry.new
        )
      end

      # Lookup must not register a participant, including during shutdown.
      def existing_ownership = @runtime.__shutdown_participant(key: TeamOwnershipRegistry)

      def current? = @runtime.equal?(Phronomy::Runtime.instance)

      def submit(**options, &operation)
        Phronomy::Execution.submit(runtime: @runtime, **options, &operation)
      end
    end
  end
end
