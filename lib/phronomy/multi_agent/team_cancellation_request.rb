# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # One Team run's local cancellation responsibility and child observations.
    # The host performs durable work; callbacks only retain intent and wake it.
    # @api private
    class TeamCancellationRequest
      attr_reader :team_execution_id, :token, :observations

      def initialize(team_execution_id:, admissions:)
        @team_execution_id = team_execution_id.to_s.freeze
        @admissions = admissions
        @token = Phronomy::Concurrency::CancellationToken.new
        @observations = {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @registration = nil
        @admitted = @pending = @terminal = @confirmed = false
        @failure = nil
      end

      # Admission precedes subscription, which can deliver inline. Each host
      # attachment gets a new identity so a previously taken callback stays stale.
      def attach
        @mutex.synchronize do
          raise Phronomy::Error, "Team cancellation request already has a host" if @registration

          unless @admitted
            @admissions.admit!(self)
            @admitted = true
          end
          @registration = Object.new.freeze
        end
      end

      def request(registration)
        @mutex.synchronize do
          return false unless @registration.equal?(registration) && !@terminal && !@confirmed

          @pending = true
          @condition.broadcast
          true
        end
      end

      def pending?
        @mutex.synchronize { @pending }
      end

      def failure
        @mutex.synchronize { @failure }
      end

      def failed(error)
        @mutex.synchronize { @failure = error if @pending }
      end

      # The caller has confirmed a durable cancellation or terminal disposition.
      # Keep admission through notification; shutdown must not pass between the
      # durable write and the signal to an existing child.
      def confirm(cancel:, terminal: false)
        @token.cancel! if cancel
        @mutex.synchronize do
          @confirmed = true if cancel
          @terminal = true if terminal
          @pending = false
          @failure = nil
          release_if_idle
          @condition.broadcast
        end
      end

      def terminal
        @mutex.synchronize do
          @terminal = true
          @pending = false
          @failure = nil
          release_if_idle
          @condition.broadcast
        end
      end

      # Fencing and the pending decision are atomic with callback acceptance.
      # An unresolved request retains admission, token and physical observations.
      def detach(registration)
        @mutex.synchronize do
          return unless @registration.equal?(registration)

          @registration = nil
          release_if_idle
          @pending
        end
      end

      # The existing synchronous Team host can receive control while a child is
      # unfinished. Its source TaskResult is never settled by this observation.
      def wait(operation)
        completed = false
        value = error = nil
        subscriptions = Phronomy::Concurrency::ResultSubscriptions.new
        subscriptions.result(operation) do |result, failure|
          @mutex.synchronize do
            value, error, completed = result, failure, true
            @condition.broadcast
          end
        end
        loop do
          action = @mutex.synchronize do
            @condition.wait(@mutex) until @pending || completed
            @pending ? :control : :complete
          end
          if action == :control
            yield
          else
            raise error if error
            return value
          end
        end
      ensure
        subscriptions&.close
      end

      private

      def release_if_idle
        return if @registration || @pending || !@admitted

        @admissions.release!(self)
        @admitted = false
      end
    end
  end
end
