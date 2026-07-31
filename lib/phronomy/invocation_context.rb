# frozen_string_literal: true

module Phronomy
  # Carries all per-invocation context values through the call stack.
  #
  # +InvocationContext+ is a plain value object (struct-like, frozen on
  # creation) that replaces ad-hoc +Thread.current[...]+ propagation.
  # Pass it explicitly wherever context needs to cross a method boundary
  # or be handed to a child {Task} / {TaskGroup}.
  #
  # @example Build a context for a new agent invocation
  #   ctx = Phronomy::InvocationContext.new(
  #     thread_id: "conv-123",
  #     cancellation_token: Phronomy::Concurrency::CancellationToken.timeout_after(30)
  #   )
  #   agent.invoke("Hello", invocation_context: ctx)
  class InvocationContext
    # @return [String, nil] conversation / workflow thread identifier
    attr_reader :thread_id

    # @return [String, nil] session identifier (e.g. Rails session id)
    attr_reader :session_id

    # @return [String, nil] end-user identifier for tracing / audit
    attr_reader :user_id

    # @return [CancellationToken, nil]
    attr_reader :cancellation_token

    # @return [Deadline, nil]
    attr_reader :deadline

    # @return [Object, nil] OpenTelemetry / tracing span
    attr_reader :tracer_span

    # @return [Integer, nil] max tokens the agent may consume this invocation
    attr_reader :token_budget

    # @return [#call, nil] invocation-specific Tool approval policy. The callable
    #   receives Phronomy::Agent::ApprovalEvaluationRequest.
    attr_reader :approval_policy

    # @return [Object, nil] redaction policy applied to tool args / results
    attr_reader :redaction_policy

    # @return [String, nil] unique identifier for this task in the trace tree
    attr_reader :task_id

    # @return [String, nil] task_id of the parent span / task
    attr_reader :parent_task_id

    # @param thread_id [String, nil]
    # @param session_id [String, nil]
    # @param user_id [String, nil]
    # @param cancellation_token [CancellationToken, nil]
    # @param deadline [Deadline, nil]
    # @param tracer_span [Object, nil]
    # @param token_budget [Integer, nil]
    # @param approval_policy [#call, nil] invocation-specific Tool approval policy
    # @param redaction_policy [Object, nil]
    # @param task_id [String, nil]
    # @param parent_task_id [String, nil]
    # @api private
    def initialize(
      thread_id: nil,
      session_id: nil,
      user_id: nil,
      cancellation_token: nil,
      deadline: nil,
      tracer_span: nil,
      token_budget: nil,
      approval_policy: nil,
      redaction_policy: nil,
      task_id: nil,
      parent_task_id: nil
    )
      @thread_id = thread_id
      @session_id = session_id
      @user_id = user_id
      @cancellation_token = cancellation_token
      @deadline = deadline
      @tracer_span = tracer_span
      @token_budget = token_budget
      @approval_policy = approval_policy
      @redaction_policy = redaction_policy
      @task_id = task_id
      @parent_task_id = parent_task_id
    end

    # Returns a new +InvocationContext+ with the given attributes merged in.
    # All other attributes are carried over unchanged.
    #
    # @param overrides [Hash] keyword arguments to override
    # @return [InvocationContext]
    # @api private
    def merge(**overrides)
      InvocationContext.new(
        thread_id: overrides.fetch(:thread_id, @thread_id),
        session_id: overrides.fetch(:session_id, @session_id),
        user_id: overrides.fetch(:user_id, @user_id),
        cancellation_token: overrides.fetch(:cancellation_token, @cancellation_token),
        deadline: overrides.fetch(:deadline, @deadline),
        tracer_span: overrides.fetch(:tracer_span, @tracer_span),
        token_budget: overrides.fetch(:token_budget, @token_budget),
        approval_policy: overrides.fetch(:approval_policy, @approval_policy),
        redaction_policy: overrides.fetch(:redaction_policy, @redaction_policy),
        task_id: overrides.fetch(:task_id, @task_id),
        parent_task_id: overrides.fetch(:parent_task_id, @parent_task_id)
      )
    end

    # Convenience: returns the cancellation token or a new never-cancelled token.
    # @return [CancellationToken]
    # @api private
    def effective_cancellation_token
      @cancellation_token || Phronomy::Concurrency::CancellationToken.new
    end

    # Returns the cancellation token to use for an invocation, taking both the
    # explicit +cancellation_token+ and the +deadline+ into account.
    #
    # - When +cancellation_token+ is set, it is returned unchanged.
    # - When only +deadline+ is set, a new {CancellationToken} is created and
    #   the deadline is attached to it via {Deadline#attach_to}.
    # - When neither is set, returns +nil+.
    #
    # @return [CancellationToken, nil]
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
