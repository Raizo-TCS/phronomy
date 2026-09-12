# frozen_string_literal: true

module Phronomy
  # Public adapter for synchronous application I/O or computation.
  # This uses the existing bounded OffloadPool. It does not execute logical
  # waits, persist work, force-stop a running block, or create a scheduler.
  module Blocking
    # Submits synchronous application work to the default Runtime OffloadPool.
    # Admission never waits for queue space. Admission StandardError failures
    # become failed Tasks; accepted work retains the pool's Task unchanged.
    # A timeout/cancellation can settle that Task before a running worker exits.
    # The block must not wait for another Agent, Workflow, or Task.
    # @param timeout [Numeric, nil] operation deadline, including queue time
    # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
    # @yield synchronous application work
    # @return [Phronomy::Task] original accepted Task or failed admission Task
    # @raise [ArgumentError] if no block is supplied
    # @api public
    def self.call_async(timeout: nil, cancellation_token: nil, &block)
      raise ArgumentError, "Blocking.call_async requires a block" unless block

      begin
        Phronomy::Runtime.instance.offload.submit(
          on_full: :raise,
          timeout: timeout,
          cancellation_token: cancellation_token,
          &block
        )
      rescue => error
        Phronomy::Task.failed(error, name: "blocking-admission-failed")
      end
    end
  end
end
