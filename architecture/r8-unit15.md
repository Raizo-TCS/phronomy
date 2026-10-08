# r8 unit15: Generation contract boundaries

This responsibility refactor is based on applied unit14, commit
`97c3d76b35594bb971a60a2932410ddf22e48d3a` (tree
`c326196212a4ac369294a9ccb936619813e51250`).

## B05: Agent operation connection

Generation previously used `send(:__invoke_async_with_event_sink, ...)` to
select Agent's private per-execution listener. It now constructs each Agent
once with its public `on_event:` option and calls public `invoke_async`.

The private Generation `AgentOperation` owns the connection, not Agent execution:

- Each returned TaskResult supplies that call's terminal result or original
  failure. Terminal incarnation notifications are not interpreted a second time.
- Approval remains a listener notification while the Agent TaskResult is pending.
  Generation retains its existing policy: approval suspension fails the pipeline.
- Pending submissions retain their Generation listeners in Workflow entry order.
  Agent continues to own admission. A rejected overlapping call cannot replace
  another call's approval listener; a queued call may be admitted after the prior
  result settles. Only the corresponding settled or synchronously failed request
  is removed. Result callbacks are thread-safe and never wait on the EventLoop.
- Agent instances and their conversations are reused across iterations and
  pipeline invocations. No per-call Agent creation, automatic cancellation,
  retry policy, durable child tracking, or new runtime registry is introduced.
- The unused private Agent event-sink method is removed. Per-invocation public
  `on_event:` arguments remain unsupported.

`AgentResultReceiver` and `PipelineState` retain event interpretation, parsing,
request correlation, stale-result rejection, review feedback and trust decisions.
Their rule bodies are unchanged. `WorkflowBuilder` retains state definitions and
entry order. Its private operation port is not a new public Agent API.

The connection relies on existing public Agent guarantees: one admitted
execution per Agent, ordered incarnation notifications, and TaskResult settlement
for terminal results. Approval does not settle the TaskResult. Handoff remains
outside GeneratorVerifier completion semantics, as before.

## B06: Default parser composition

`runtime_composition/generation_defaults.rb` selects the existing JsonParser
through a private one-time factory binding. Generation lazily creates and reuses
one default parser per pipeline only when default parsing is needed. Boot creates
no parser, Agent, Persistence or Runtime for this binding.

Generation owns `default_parse_draft` and `default_parse_review`, including the
existing ParseError fallback payloads. Existing custom parser callables take
precedence. No application configuration changes are required. OutputParser's
contract and its concrete implementations are unchanged.

## Scope and verification

AST regression gates reject concrete parser selection and the removed private
Agent invocation in Generation. Public-only Agent doubles cover inline completion,
busy failure, queued admission, stale terminal notifications, timeout, cancellation
and approval while pending. Real Agent integration covers approval in both phases
and retained conversations. Domain event-rule tests use the private Generation
operation port; they no longer pretend a private Agent method is the public API.

Public signatures, result shape, stored schemas, generation/review decisions,
parser fallback values and default iteration limits are preserved. The internal
result-observation plumbing changes; this is not merely a physical file move.
F01 durable Workflow children remain deferred feature work. This checkpoint does
not certify all framework dependencies or all concrete Engine responsibilities.
