# frozen_string_literal: true

module Phronomy
  module Graph
    # Represents a set of branches that execute concurrently as a single graph node.
    #
    # Each branch is a callable (Proc, lambda, or any object responding to #call)
    # that receives the current state and returns either a Hash of field updates or
    # nil.  All branches run in separate threads; their results are merged in
    # registration order using the following policy:
    #
    #   :replace fields  — last-write-wins (rightmost branch wins)
    #   :append  fields  — all Arrays are concatenated
    #   :merge   fields  — all Hashes are deep-merged (rightmost wins on conflict)
    #
    # @example Basic two-branch node
    #   graph.add_parallel_node(:step,
    #     ->(state) { { field_a: "from_a" } },
    #     ->(state) { { field_b: "from_b" } }
    #   )
    #
    # @example With timeout and failure policy
    #   graph.add_parallel_node(:step,
    #     branch_a, branch_b,
    #     timeout: 10,
    #     on_error: :best_effort
    #   )
    #
    # Timeout support
    #   Pass +timeout:+ (seconds, Numeric) to limit how long the node may run.
    #   If any thread does not finish within the limit, all threads are killed and
    #   +Phronomy::Graph::TimeoutError+ is raised (for +:raise+ policy) or recorded
    #   in the result hash under +:parallel_errors+ (for +:best_effort+ policy).
    #
    # Failure policies (+on_error:+)
    #   :raise (default)
    #     Re-raises the first exception after all threads are joined.
    #     Mirrors the original Thread#value semantics.
    #   :best_effort
    #     Collects successful results and stores any errors in the update Hash
    #     under the key +:parallel_errors+ (Array of exception objects).
    #     The caller's state class should declare:
    #       field :parallel_errors, type: :append, default: -> { [] }
    #     Unknown keys are silently ignored by the State#merge machinery.
    class ParallelNode
      # @param branches  [Array<#call>]     at least one callable branch required
      # @param timeout   [Numeric, nil]     wall-clock limit in seconds; nil = unlimited
      # @param on_error  [Symbol]           :raise (default) or :best_effort
      def initialize(branches, timeout: nil, on_error: :raise)
        raise ArgumentError, "branches must be a non-empty Array" if branches.empty?
        unless %i[raise best_effort].include?(on_error)
          raise ArgumentError, "on_error must be :raise or :best_effort, got #{on_error.inspect}"
        end

        @branches = branches
        @timeout = timeout
        @on_error = on_error
      end

      # Executes all branches concurrently and merges their results.
      #
      # @param state [Object] state object (includes Phronomy::Graph::State)
      # @return [Hash, nil] merged update hash, or nil when all branches return nil
      def call(state)
        threads = @branches.map { |branch| Thread.new { branch.call(state) } }
        deadline = @timeout ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout) : nil

        if @on_error == :best_effort
          gather_best_effort(threads, deadline)
        else
          gather_raise(threads, deadline)
        end
      end

      private

      # Joins all threads, enforcing the deadline. Re-raises branch exceptions.
      def gather_raise(threads, deadline)
        if deadline
          threads.each do |t|
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            next if t.join([remaining, 0].max)

            # Thread did not finish within the time limit.
            # Use Thread#raise instead of Thread#kill so that ensure blocks in
            # branches (DB connection return, Mutex release, etc.) are executed.
            timeout_error = Phronomy::Graph::TimeoutError.new(
              "parallel branch timed out after #{@timeout}s"
            )
            threads.each { |thr| thr.raise(timeout_error) unless thr.stop? }
            threads.each { |thr| thr.join(0.1) rescue nil }
            raise Phronomy::Graph::TimeoutError,
              "parallel branch timed out after #{@timeout}s"
          end
        end

        # All threads are done. Thread#value re-raises any stored exception.
        merge_results(threads.map(&:value))
      end

      # Joins all threads, collecting errors instead of re-raising them.
      def gather_best_effort(threads, deadline)
        errors = []
        results = threads.map do |t|
          if deadline
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            # Thread#join(limit) re-raises the thread's stored exception in the calling
            # thread when the thread terminated abnormally within the limit.
            # Rescue here so the error is collected rather than propagated.
            begin
              joined = t.join([remaining, 0].max)
            rescue => e
              errors << e
              next nil
            end
            if joined.nil?
              timeout_error = Phronomy::Graph::TimeoutError.new(
                "branch timed out after #{@timeout}s"
              )
              t.raise(timeout_error) unless t.stop?
              t.join(0.1) rescue nil
              errors << Phronomy::Graph::TimeoutError.new(
                "branch timed out after #{@timeout}s"
              )
              next nil
            end
          end

          begin
            t.value
          rescue => e
            errors << e
            nil
          end
        end

        merged = merge_results(results) || {}
        merged[:parallel_errors] = errors unless errors.empty?
        merged.empty? ? nil : merged
      end

      # Merges an Array of per-branch result Hashes (nils are skipped).
      def merge_results(results)
        merged = results.compact.each_with_object({}) do |result, acc|
          next unless result.is_a?(Hash)

          result.each do |key, val|
            acc[key] = acc.key?(key) ? merge_values(acc[key], val) : val
          end
        end

        merged.empty? ? nil : merged
      end

      # Merges two values that share the same state field key across branches.
      # Arrays are concatenated; Hashes are deep-merged; scalars use last-write-wins.
      def merge_values(old_val, new_val)
        if old_val.is_a?(Array) && new_val.is_a?(Array)
          old_val + new_val
        elsif old_val.is_a?(Hash) && new_val.is_a?(Hash)
          old_val.merge(new_val)
        else
          new_val
        end
      end
    end
  end
end
