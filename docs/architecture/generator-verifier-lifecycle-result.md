# GeneratorVerifier: approval, lifetime and result contract

Generation (C03) is a responsibility group, not a Ruby namespace.
Phronomy::GeneratorVerifier is the public draft/review/retry API. Applications
choose the Agent classes, Tools, prompts, evaluation thresholds and authorization
policy. Generation owns composition and evaluation; Agent (C04) owns Tool
authorization, durable execution, cancellation and safe unload.

Correct behavior takes priority over backward compatibility. This change removes
trusted/trusted?, raise_if_untrusted and LowConfidenceError. There are no legacy
aliases or compatibility branches.

## Application operations

Construct with new or open. Construction acquires both owned Agents, synchronously;
a failure acquiring the second releases the first. Prepare the pipeline before
entering EventLoop. Both Agents and their conversations are reused between
invocations. open requires a block, returns its value, and always attempts release!.
Complete asynchronous invocations inside the block; arbitrary returned Tasks are
not automatically awaited.

invoke waits for the final Result. invoke_async returns TaskResult. A pipeline
admits one invocation at a time; independent concurrent conversations need
independent pipelines. Workflow state, approvals and cancellation are per invocation.
config is forwarded to Workflow. Only the private cancellation token and any
InvocationContext are forwarded to Agent operations, not Workflow-specific
identity or settings.

on_approval receives an Approval with invocation_id, phase (:draft/:review) and
request (Agent::ToolApprovalRequest). It is a short, thread-safe notification,
not a blocking UI callback or a function whose return value authorizes a Tool.
Use approval.respond_async(approved: true/false), or enqueue the Approval for an
external UI to answer later. The response Task observes the resumed Agent's
terminal outcome and returns nil. Do not wait for it inside the callback.

Without a callback, approval_requests exposes notifications issued in the current
invocation, including answered ones. It is not a mirror of current durable
approval state. Suspension is not an error and no implicit approval or denial is
performed. Expiry and cancellation are application choices. Stale invocation
handles fail; Agent validates execution/request identity and duplicate decisions.
Invalid replies fail their own Task without cancelling the original invocation.
Callback exceptions cancel the owned invocation and remain its primary error.

cancel_async requests cancellation without mutating a caller-owned cancellation
token. It can also address a known Agent execution after a Handoff outcome.
Completion acknowledges the cancellation operations, not physical quiescence;
observe the invocation result separately. release! delegates safety to Agent's
unload!, preserves saved history and does not close the Store. It rejects active
invocations rather than cancelling or denying approvals implicitly.

All owners are attempted during release. Successful owners are removed; failed
ones remain available for cancellation or another release attempt. Partial release
cannot be followed by a new invocation. Successful release is idempotent (true,
then false). CleanupError exposes pipeline, failures, result and primary_error;
when both application work and cleanup fail, neither exception nor the recovery
handle is lost. Its cause is the primary exception, if present.

Handoff coordination is outside this composition's contract. A Handoff result
raises generation.unsupported_handoff rather than leaving the Workflow pending.
Agent retains authority over durable coordination and safe release; Generation
never purges unfinished work or clears retention to make cleanup appear successful.
Reconstructing an in-flight GeneratorVerifier after process restart is not offered.

## Agent cancellation during approval suspension

An approval suspension ends the current FSM session, but the logical execution
and its original Task remain pending. C04 now retains the cancellation connection
through this suspension, routes cancellation to its existing quiescence/terminal
commit barrier, and closes the subscription on resume or termination. Generation
does not implement this Agent transition itself. Cancellation and approval racing
at the suspension boundary must not create competing terminal/resume commits.

## Results and decisions

Result is immutable, including nested data. It contains output, confidence,
confidence_threshold, review_approved, citations, iterations, review_notes,
termination_reason and interrupted_phase. accepted? describes satisfaction of the
configured evaluation conditions, not an application's decision to publish.

Confidence is the lower final draft/review score. A completed evaluation is accepted
only when review_approved is true and confidence meets the threshold. At the
iteration limit, acceptance wins if both conditions hold; otherwise the reason is
iteration_limit. Scores and threshold are finite 0..1; max_iterations is a positive
Integer. Output parser fallbacks and normalization are separate from configuration
validation.

A Tool denial is a normal Agent rejected outcome, not a parser input or automatic
retry. Result reports tool_rejected and the interrupted phase. Confidence and
review_approved are nil because the evaluation did not complete. Rejection during
draft has no output; rejection during review retains the draft. iterations counts
completed drafts.

to_h includes all fields. Result.from_h accepts that Hash and its JSON round trip,
rejecting unknown fields, invalid types and contradictory reasons. Citation keys
are normalized to strings. Equality and hash use all semantic fields, so a change
in review decision or threshold is observable. Applications own storage/transport
choices and any intentional projection of these fields.

raise_if_unaccepted defaults to false. When explicitly true, an unaccepted Result
raises GeneratorVerifier::UnacceptedResultError with result and code. Provider,
parser, cancellation and callback errors do not become evaluation failures.

## Ownership boundaries

C03 continues to depend on C04 Agent, C02 Workflow, C13 Execution and C17
OutputParser. Cancellation subscriptions use the existing execution abstraction.
No Agent registry, private Scope construction, Storage operation or Engine
implementation is accessed from Generation.

Private AgentOperation connects public Agent commands and notifications.
Invocation owns one call's child observations, subscription lifetime and approval
routing. WorkflowBuilder/AgentResultReceiver/PipelineState retain graph, event
conversion and correlated state application. Result owns evaluation facts and
their invariants.

## Application migration

Use open around the complete application operation, including validation retries.
Use accepted? and termination_reason, not score-only trusted?. For an external
approval UI, start invoke_async, enqueue on_approval notifications, respond through
the original Approval handle, and observe the final Task before release.

examples/19_trust_pipeline is the direct consumer. examples/27_issue_analyzer only
mentions GeneratorVerifier in descriptive classification text and requires no API
migration. Full old/new runnable sources are available through the source diff.
