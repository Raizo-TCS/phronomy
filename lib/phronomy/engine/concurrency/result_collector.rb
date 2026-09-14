# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Shared input-order fan-in and terminal arbitration. No application code or
    # completion callback runs while this collector's lock is held.
    # @api private
    class ResultCollector
      def initialize(size, &finished)
        @mutex = Mutex.new
        @outcomes = Array.new(size)
        @remaining = size
        @closed = false
        @sources = {}.compare_by_identity
        @subscriptions = Subscriptions.new
        @finished = finished
      end

      def while_open
        @mutex.synchronize { yield unless @closed }
      end

      def open?
        @mutex.synchronize { !@closed }
      end

      def watch(index, result, &recorded)
        subscribe = @mutex.synchronize do
          return if @closed

          first = !@sources.key?(result)
          (@sources[result] ||= {})[index] = recorded
          first
        end
        if subscribe
          @subscriptions.result(result) { receive(result) }
        elsif result.done?
          receive(result)
        end
      end

      def finish(kind)
        snapshot = @mutex.synchronize do
          return false if @closed
          return false if kind == :completed && @remaining > 0

          @closed = true
          snapshot_locked
        end
        deliver(kind, snapshot)
        true
      end

      private

      def receive(result)
        status, value, error = result.__snapshot
        callbacks = []
        snapshot = @mutex.synchronize do
          return if @closed

          @sources.fetch(result).each do |index, callback|
            next if @outcomes[index]

            @outcomes[index] = TaskResult::Outcome.new(index: index,
              status: status, value: value, error: error)
            @remaining -= 1
            callbacks << callback if callback
          end
          if @remaining.zero?
            @closed = true
            snapshot_locked
          end
        end
        deliver(:completed, snapshot) if snapshot
        callbacks.each(&:call)
      end

      def snapshot_locked
        @outcomes.each_with_index.map do |outcome, index|
          outcome || TaskResult::Outcome.new(index: index,
            status: :unfinished, value: nil, error: nil)
        end.freeze
      end

      def deliver(kind, snapshot)
        finished = @mutex.synchronize do
          @sources.clear
          @outcomes.clear
          callback = @finished
          @finished = nil
          callback
        end
        @subscriptions.close
        finished.call(kind, snapshot)
      end
    end
  end
end
