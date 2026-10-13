# frozen_string_literal: true

require "securerandom"

module Phronomy
  class GeneratorVerifier
    # Owns one run's subscriptions, child observations and application approval route.
    # Agent owns durable execution, authorization and physical release safety.
    # @api private
    class Invocation
      attr_reader :id, :result, :config

      def initialize(config:, on_approval:, on_finish:)
        @id = SecureRandom.uuid.freeze
        @result = Phronomy::TaskResult.deferred(name: "generation:#{@id}")
        @mutex = Mutex.new
        @pending = 0
        @workflow_done = false
        @finished = false
        @approvals = []
        @on_approval, @on_finish = on_approval, on_finish
        @token = Phronomy::Concurrency::CancellationToken.new
        @subscriptions = Phronomy::Concurrency::Subscriptions.new
        @config = config.merge(cancellation_token: @token).freeze
        @agent_config = {cancellation_token: @token}
        @agent_config[:invocation_context] = config[:invocation_context] if config.key?(:invocation_context)
        @agent_config.freeze
        @subscriptions.cancellation(config[:cancellation_token]) { @token.cancel! }
      end

      def approvals
        @mutex.synchronize { @approvals.dup.freeze }
      end

      def cancel
        @token.cancel!
      end

      def start(operation, phase, input, listener:)
        observe do
          @token.raise_if_cancelled!
          operation.start(input, config: @agent_config, listener: ->(event) {
            if event.type == :approval_required
              notify_approval(operation, phase, event.payload.fetch(:request))
            else
              listener.call(event)
            end
          })
        end
      end

      def respond(approval)
        observe(check_approval: approval) { yield }
      rescue => error
        Phronomy::TaskResult.failed(error)
      end

      def follow(workflow_task, &build_result)
        workflow_task.on_complete do |state, error|
          begin
            value = build_result.call(state) unless error
          rescue => result_error
            error = result_error
          end
          finish_workflow(value, error)
        end
        @result
      end

      def fail_start(error)
        finish_workflow(nil, error)
        @result
      end

      private

      def notify_approval(operation, phase, request)
        approval = Approval.new(invocation: self, operation: operation, phase: phase, request: request)
        deliver = @mutex.synchronize do
          next false if @workflow_done || @finished
          @approvals << approval
          true
        end
        @on_approval&.call(approval) if deliver
      rescue => error
        @mutex.synchronize { @primary_error ||= error }
        cancel
      end

      def observe(check_approval: nil)
        reserved = false
        observed = false
        @mutex.synchronize do
          if @finished || @workflow_done || (check_approval && !@approvals.include?(check_approval))
            raise Phronomy::Error.new("Generation invocation is no longer accepting operations",
              code: "generation.inactive")
          end
          @pending += 1
          reserved = true
        end
        task = yield
        unless task.is_a?(Phronomy::TaskResult)
          raise TypeError, "Agent operation must return TaskResult"
        end
        task.on_complete { |_value, _error| child_finished }
        observed = true
        task
      ensure
        child_finished if reserved && !observed
      end

      def child_finished
        @mutex.synchronize { @pending -= 1 }
        try_finish
      end

      def finish_workflow(value, error)
        @mutex.synchronize do
          @workflow_done = true
          @value, @error = value, error
        end
        cancel if error
        try_finish
      end

      def try_finish
        completion = @mutex.synchronize do
          next if @finished || !@workflow_done || !@pending.zero?
          @finished = true
          [@value, @primary_error || @error]
        end
        return unless completion

        @subscriptions.close
        @on_finish.call
        value, error = completion
        if error.is_a?(Phronomy::CancellationError)
          @result.cancel!(error)
        elsif error
          @result.fail(error)
        else
          @result.complete(value)
        end
      end
    end
  end
end
