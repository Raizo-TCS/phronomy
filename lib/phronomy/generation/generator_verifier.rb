# frozen_string_literal: true

module Phronomy
  # Application-facing draft/review/retry composition.
  # Owns its Agent instances; Tool authorization remains an application decision.
  class GeneratorVerifier
    DEFAULT_CONFIDENCE_THRESHOLD = 0.7
    DEFAULT_MAX_ITERATIONS = 3

    private_constant :PipelineState, :WorkflowBuilder, :AgentResultReceiver,
      :AgentOperation, :Invocation, :Protocol

    def self.open(**options)
      raise ArgumentError, "GeneratorVerifier.open requires a block" unless block_given?
      pipeline = new(**options)
      value = nil
      primary = nil
      begin
        returned = yield pipeline
        value = returned.is_a?(Phronomy::TaskResult) ? returned.wait_result : returned
      rescue Exception => error # rubocop:disable Lint/RescueException -- retain Interrupt during cleanup
        primary = error
        raise
      ensure
        begin
          pipeline.release!
        rescue => cleanup
          failures = cleanup.is_a?(CleanupError) ? cleanup.failures : [{phase: nil, error: cleanup}]
          raise CleanupError.new(pipeline: pipeline, failures: failures,
            result: value, primary_error: primary), cause: primary || failures.first.fetch(:error)
        end
      end
      value
    end

    def initialize(draft_agent:, review_agent:, draft_prompt_builder:, review_prompt_builder:,
      citation_schema: Protocol::DEFAULT_CITATION, schema_delivery: :native,
      confidence_threshold: DEFAULT_CONFIDENCE_THRESHOLD,
      max_iterations: DEFAULT_MAX_ITERATIONS, raise_if_unaccepted: false, on_approval: nil)
      ensure_blocking_allowed!(:new)
      unless %i[native none].include?(schema_delivery)
        raise ArgumentError, "schema_delivery must be :native or :none"
      end
      unless confidence_threshold.is_a?(Numeric) && confidence_threshold.real? && confidence_threshold.to_f.finite? &&
          (0.0..1.0).cover?(confidence_threshold)
        raise ArgumentError, "confidence_threshold must be a finite number in 0..1"
      end
      unless max_iterations.is_a?(Integer) && max_iterations.positive?
        raise ArgumentError, "max_iterations must be a positive Integer"
      end
      [draft_prompt_builder, review_prompt_builder, on_approval].compact.each do |callable|
        raise ArgumentError, "builders and on_approval must be callable" unless callable.respond_to?(:call)
      end
      unless raise_if_unaccepted == true || raise_if_unaccepted == false
        raise ArgumentError, "raise_if_unaccepted must be true or false"
      end
      @mutex = Mutex.new
      @status = :idle
      @operations = {}
      @active = nil
      @threshold = confidence_threshold.to_f
      @max_iterations = max_iterations
      @raise_if_unaccepted = raise_if_unaccepted
      @on_approval = on_approval
      @draft_prompt_builder, @review_prompt_builder = draft_prompt_builder, review_prompt_builder
      draft_schema = Protocol.draft(citation_schema)
      begin
        @operations[:draft] = AgentOperation.new(draft_agent, output_schema: draft_schema, schema_delivery: schema_delivery)
        @operations[:review] = AgentOperation.new(review_agent, output_schema: Protocol::REVIEW, schema_delivery: schema_delivery)
      rescue Exception => primary # rubocop:disable Lint/RescueException -- release partially acquired resources
        begin
          release!
        rescue CleanupError => cleanup
          raise CleanupError.new(pipeline: self, failures: cleanup.failures,
            primary_error: primary), cause: primary
        end
        raise
      end
    end

    def invoke(input, config: {})
      ensure_blocking_allowed!(:invoke)
      invoke_async(input, config: config).wait_result
    end

    def invoke_async(input, config: {})
      invocation = @mutex.synchronize do
        assert_idle!
        current = Invocation.new(config: config, on_approval: @on_approval,
          on_finish: -> { @mutex.synchronize { @active = nil } })
        @active = current
      end
      invocation.follow(compiled_workflow.invoke_async({input: input}, config: invocation.config)) do |state|
        build_result(state)
      end
    rescue => error
      invocation ? invocation.fail_start(error) : Phronomy::TaskResult.failed(error)
    end

    # Notifications issued in the current invocation, including already-answered
    # requests. This is not a replica of the Agent's durable approval state.
    def approval_requests
      @mutex.synchronize { @active }&.approvals || [].freeze
    end

    # Requests cancellation; this Task does not promise physical quiescence.
    # Await the invocation separately, then use release! to check safe release.
    def cancel_async
      current, operations = @mutex.synchronize do
        if @status == :releasing
          raise Phronomy::Error.new("Generation is releasing", code: "generation.busy")
        end
        [@active, @operations.values.dup]
      end
      current&.cancel
      tasks = operations.filter_map(&:cancel_async)
      Phronomy::TaskResult.all_settled(tasks).map do |outcomes|
        failure = outcomes.find(&:error)
        raise failure.error if failure
        !!current || !tasks.empty?
      end
    rescue => error
      Phronomy::TaskResult.failed(error)
    end

    def release!
      ensure_blocking_allowed!(:release!)
      operations = @mutex.synchronize do
        return false if @status == :released
        if @active || @status == :releasing
          raise Phronomy::Error.new("Generation is busy", code: "generation.busy")
        end
        @status = :releasing
        @operations.dup
      end
      failures = []
      operations.each do |phase, operation|
        operation.unload!
        @mutex.synchronize { @operations.delete(phase) }
      rescue => error
        failures << {phase: phase, error: error}
      end
      @mutex.synchronize { @status = failures.empty? ? :released : :release_failed }
      unless failures.empty?
        raise CleanupError.new(pipeline: self, failures: failures), cause: failures.first.fetch(:error)
      end
      @compiled_workflow = nil
      true
    end

    private

    def assert_idle!
      if @status != :idle
        raise Phronomy::Error.new("Generation is #{@status}", code: "generation.released")
      end
      raise Phronomy::Error.new("Generation is busy", code: "generation.busy") if @active
    end

    def ensure_blocking_allowed!(operation)
      if Phronomy::WaitPolicy.blocking_forbidden?
        raise Phronomy::EventLoopReentrancyError, "GeneratorVerifier##{operation} cannot run on EventLoop"
      end
    end

    def compiled_workflow
      @compiled_workflow ||= WorkflowBuilder.new(
        draft_agent: @operations.fetch(:draft),
        review_agent: @operations.fetch(:review),
        draft_prompt_builder: @draft_prompt_builder,
        review_prompt_builder: @review_prompt_builder,
        threshold: @threshold, max_iterations: @max_iterations,
        start_operation: ->(operation, phase, input, listener:) {
          @mutex.synchronize { @active }.start(operation, phase, input, listener: listener)
        }
      ).build
    end

    def build_result(state)
      interrupted = state.interrupted_phase
      confidence = interrupted ? nil : [state.self_score, state.review_score].min
      approved = interrupted ? nil : state.approved
      accepted = Result.accepted?(confidence: confidence, confidence_threshold: @threshold, review_approved: approved)
      result = Result.new(output: state.output, confidence: confidence,
        confidence_threshold: @threshold, review_approved: approved,
        citations: state.citations, iterations: state.iteration, review_notes: state.review_notes,
        termination_reason: if interrupted
                              state.pipeline_error ? "output_failed" : "tool_rejected"
                            else
                              (accepted ? "accepted" : "iteration_limit")
                            end,
        interrupted_phase: interrupted,
        failure: output_failure_diagnostic(state.pipeline_error))
      if @raise_if_unaccepted && !result.accepted?
        raise UnacceptedResultError.new(result), cause: state.pipeline_error
      end
      result
    end

    def output_failure_diagnostic(error)
      return nil unless error
      Phronomy::Error.diagnostic(error).merge("execution_id" => error.execution_id,
        "schema_digest" => error.schema_digest, "reason" => error.reason, "violations" => error.violations)
    end
  end
end
