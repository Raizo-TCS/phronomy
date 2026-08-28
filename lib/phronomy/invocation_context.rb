# frozen_string_literal: true

module Phronomy
  # Carries per-invocation control, policy, and tracing context through the call stack.
  #
  # +InvocationContext+ is a plain struct-like value carrier that replaces
  # ad-hoc +Thread.current[...]+ propagation.
  # Pass it explicitly wherever context needs to cross a method boundary.
  #
  # Generic conversation/session identity is deliberately not part of this
  # object. Use purpose-specific domain identifiers and application tracing
  # metadata instead.
  #
  # @example Build a context for a new agent invocation
  #   ctx = Phronomy::InvocationContext.new(
  #     task_id: "request-123",
  #     cancellation_token: Phronomy::Concurrency::CancellationToken.timeout_after(30)
  #   )
  #   agent.invoke("Hello", invocation_context: ctx)
  #
  # @api public
  class InvocationContext
    attr_reader :user_id, :cancellation_token, :deadline,
      :token_budget, :approval_policy, :redaction_policy, :task_id,
      :parent_task_id

    # @api public
    def initialize(
      user_id: nil,
      cancellation_token: nil,
      deadline: nil,
      token_budget: nil,
      approval_policy: nil,
      redaction_policy: nil,
      task_id: nil,
      parent_task_id: nil
    )
      @user_id = user_id
      @cancellation_token = cancellation_token
      @deadline = deadline
      @token_budget = token_budget
      @approval_policy = approval_policy
      @redaction_policy = redaction_policy
      @task_id = task_id
      @parent_task_id = parent_task_id
    end

    # @api private
    def merge(**overrides)
      InvocationContext.new(
        user_id: overrides.fetch(:user_id, @user_id),
        cancellation_token: overrides.fetch(:cancellation_token, @cancellation_token),
        deadline: overrides.fetch(:deadline, @deadline),
        token_budget: overrides.fetch(:token_budget, @token_budget),
        approval_policy: overrides.fetch(:approval_policy, @approval_policy),
        redaction_policy: overrides.fetch(:redaction_policy, @redaction_policy),
        task_id: overrides.fetch(:task_id, @task_id),
        parent_task_id: overrides.fetch(:parent_task_id, @parent_task_id)
      )
    end

    # @api private
    def effective_cancellation_token
      @cancellation_token || Phronomy::Concurrency::CancellationToken.new
    end

    # @api private
    def effective_timeout_token
      return @cancellation_token if @cancellation_token
      return nil if @deadline.nil?

      token = Phronomy::Concurrency::CancellationToken.new
      @deadline.attach_to(token)
      token
    end
  end
end
