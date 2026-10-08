# r8 unit15 migration

## Application impact

No public API, data migration or configuration changes are required.
GeneratorVerifier continues to accept draft/review Agent classes and optional
result parser callables, with the same JSON parser defaults and fallback values.
Each supplied Agent is created once and reused, retaining its conversation.

Custom Agent classes should implement the public Agent protocol: constructor
`on_event:`, `invoke_async` returning TaskResult, and approval notifications through
the constructor-bound listener. Terminal results are observed on the returned
TaskResult. A test double that emits `:done` but leaves its TaskResult pending is
not a complete implementation of that protocol and must settle its result.

The private `__invoke_async_with_event_sink` method is removed. It was not a
supported application API. Do not substitute `invoke_async(..., on_event:)`;
per-invocation listener arguments remain rejected. Register the listener at Agent
construction and observe each call's result near the call site.

`GeneratorVerifier::DefaultParser` and the private AgentOperation are framework
composition details. Applications continue to use `draft_result_parser:` and
`review_result_parser:` for custom parsing.

## Operational scope

The package applies only to core on top of unit14. Existing unit6 examples need
verification against the new core but no source migration. Restart using the
existing stop/drain procedure. Rollback is a revert of the unit15 commit; it does
not require rewriting stored data. In-flight cross-version behavior is not a new
guarantee of this refactor.
