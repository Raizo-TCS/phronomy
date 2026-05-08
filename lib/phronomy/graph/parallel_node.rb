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
    # If any branch raises an exception the error is re-raised in the calling
    # thread after all branches have completed (Thread#value semantics).
    #
    # @example Two-branch parallel node
    #   graph.add_parallel_node(:parallel_step,
    #     ->(state) { { field_a: "from_branch_a" } },
    #     ->(state) { { field_b: "from_branch_b" } }
    #   )
    class ParallelNode
      # @param branches [Array<#call>] at least one callable branch required
      def initialize(branches)
        raise ArgumentError, "branches must be a non-empty Array" if branches.empty?

        @branches = branches
      end

      # Executes all branches concurrently and merges their results.
      #
      # @param state [Object] state object (includes Phronomy::Graph::State)
      # @return [Hash, nil] merged update hash, or nil when all branches return nil
      def call(state)
        threads = @branches.map { |branch| Thread.new { branch.call(state) } }
        results = threads.map(&:value) # re-raises any exception from a branch thread

        merged = results.compact.each_with_object({}) do |result, acc|
          next unless result.is_a?(Hash)

          result.each do |key, val|
            acc[key] = if acc.key?(key)
              merge_values(acc[key], val)
            else
              val
            end
          end
        end

        merged.empty? ? nil : merged
      end

      private

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
