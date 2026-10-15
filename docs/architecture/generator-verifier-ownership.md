# GeneratorVerifier ownership and event contract

The current contract is
[GeneratorVerifier: approval, lifetime and result](generator-verifier-lifecycle-result.md).

GeneratorVerifier is the public owner of draft/review Agent composition and its
evaluation Result. AgentOperation delegates to public Agent commands. Invocation
owns per-call approval routing, cancellation subscriptions and child observations.
WorkflowBuilder builds the graph; AgentResultReceiver converts results;
PipelineState applies correlated events; Result owns immutable evaluation facts.

Both owned Agents are acquired at pipeline construction and reused until release.
Workflow contexts are fresh for each invocation. Concurrent use of one pipeline
is rejected. Approval suspension remains pending and is exposed to the application;
it is not converted to failure. Tool denial is a tool_rejected Result.
Handoff is explicitly unsupported instead of silently leaving completion pending.

The older R08/D08 and R8 unit15 documents record the historical extraction. Their
preserved score-only trust, approval-failure and lazy Agent acquisition behavior
has been superseded by the current contract.
