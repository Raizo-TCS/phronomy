# frozen_string_literal: true

module Phronomy
  # Engine implementation of the Execution mechanism protocol. Installing this
  # binding does not acquire any resources; default Runtime is resolved on use.
  # @api private
  module ExecutionBinding
    def self.supports_submission_rejection? = true

    def self.submit(pool: nil, runtime: nil, pool_name: nil, size: 10,
      queue_size: 100, on_rejected: nil, **options, &operation)
      unless pool
        runtime ||= Runtime.instance
        pool = pool_name ? runtime.pool(pool_name, size: size, queue_size: queue_size) : runtime.offload
      end
      Execution.submit_with_rejection_evidence(pool, on_rejected: on_rejected, **options, &operation)
    end

    def self.after(seconds, &callback)
      timer = Runtime.instance.timer_queue
      timer.schedule(seconds: seconds, &callback)
      -> { timer.cancel(callback) }
    end
  end
end
