# frozen_string_literal: true

module Phronomy
  # Public adapter for synchronous application I/O or computation.
  # This uses the existing bounded OffloadPool. It does not execute logical
  # waits, persist work, force-stop a running block, or create a scheduler.
  module Blocking
    # Submits synchronous application work to the default Runtime OffloadPool.
    # Admission never waits for queue space. Admission StandardError failures
    # become failed results; accepted work retains the pool's TaskResult unchanged.
    # A timeout/cancellation can settle that TaskResult before a running worker exits.
    # The block must not wait for another Agent, Workflow, or TaskResult.
    # @param timeout [Numeric, nil] operation deadline, including queue time
    # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
    # @param invocation_context [Phronomy::InvocationContext, nil] explicit context/scope
    # @yield synchronous application work
    # @return [Phronomy::TaskResult] original accepted TaskResult or failed admission TaskResult
    # @raise [ArgumentError] if no block is supplied
    # @api public
    def self.call_async(timeout: nil, cancellation_token: nil, invocation_context: nil, &block)
      raise ArgumentError, "Blocking.call_async requires a block" unless block

      begin
        unless invocation_context.nil?
          binding = Concurrency::OperationBinding.new(invocation_context: invocation_context,
            cancellation_token: cancellation_token)
        end
        result = Phronomy::Runtime.instance.offload.submit(
          on_full: :raise,
          timeout: timeout,
          cancellation_token: binding ? binding.token : cancellation_token,
          &block
        )
        binding ? binding.bind(result) : result
      rescue => error
        result = Phronomy::TaskResult.failed(error, name: "blocking-admission-failed")
        binding ? binding.bind(result) : result
      end
    end
  end
end
