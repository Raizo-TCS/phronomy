# Agent iteration budget

## Problem and meaning

Agent previously converted `max_iterations` to the generic FSM transition limit
`12 + 8 * max_iterations`. A single-Tool round currently takes ten transitions;
parallel Tool completions add further transitions. Default ten therefore stopped
the ninth Tool round before the tenth LLM call. Approval/recovery also creates new
FSM sessions, so a session counter cannot enforce an execution-wide Agent limit.

`Agent.max_iterations = N` now permits at most N logical LLM calls in one
AgentExecution, including the first and final call. Tool execution, authorization,
approval, streaming chunks and backend HTTP retries consume no additional calls.
This does not bound physical HTTP attempts, tokens, elapsed time or Tool count.

## Owners and dependency direction

| Owner | Responsibility |
|---|---|
| Application / Agent declaration | Choose the maximum logical LLM calls. |
| Agent::IterationBudget | Validate the limit and decide whether another call is allowed from AgentExecution.llm_calls. |
| Agent preparation operations | Check before context hooks and provider dispatch; capture the limit in execution metadata. |
| Agent execution/recovery record encoders | Existing durable call identity, result recording and exactly-once recovery interpretation. |
| Agent::EngineSessionBuilder / InvocationTransitions | Select generic Engine safety mode and a bound appropriate to the Agent phase graph. |
| Engine::FSMSession | Bound automatic transition chains, without knowing LLMs, Tools, Agent records or iteration policy. |
| LLMAdapter / RubyLLM backend | Existing logical-call contract, wire transport, response handling and SDK retry policy. |

There is no new mutable Agent counter and no persistence access from Engine.
The call records already used for context call sequence and recovery remain the
single authority. InitialPreparation checks before the first call. DispatchPreparation
includes pending runtime outcomes through the existing record encoder, checks the
resulting call count, then prepares and commits the next provider dispatch.
Existing durable pending-call identity prevents unknown outcomes from being
automatically redispatched. No counter is incremented by Tool or Engine events.

Engine's optional `recursion_limit_scope: :automatic_chain` counts consecutive
accepted `state_completed` transitions. Only an accepted external transition
starts a new chain; consumed/stale events or events without a transition do not.
Agent selects this mode with its declared phase count as the safety bound.
Engine's default `:session` mode retains the previous total-transition limit for
Workflow and Tool sessions. Total step count remains available for diagnostics.
This is a generic mechanism, not an Engine dependency on Agent policy.

ADR-066's allocation remains intact: Agent owns execution and recovery, C09 owns
one model operation, C06 owns Tool execution, and the backend owns SDK details.
No RubyLLM, provider-specific or example-specific code is added.

## Completion, suspension and compatibility

- The limit is a nonnegative Integer captured as `agent_max_iterations` in the
  existing execution metadata at admission. Changing a class declaration during
  approval cannot increase or reset the active run's budget. No DB schema migration.
- Resume/recovery uses the saved call records and saved limit. An older execution
  without this metadata uses the current class limit and records it when preparing
  another call. Its original limit cannot be reconstructed. Restart from legacy
  initial preparation captures the fallback before input hooks.
- A new AgentExecution gets its own limit; handing work to another Agent gives
  that Agent its own execution budget. GeneratorVerifier/SharedState orchestration
  limits remain separate policies.
- A final response on call N succeeds. If call N requests Tools, those Tools
  finish or await approval normally; the attempted next LLM call then fails with
  the existing `Phronomy::RecursionLimitError`. Completed Tool results are retained;
  no final answer or successful application outcome is fabricated.
- Zero dispatches no LLM call. Invalid limits fail before inference. Default ten
  and declaration inheritance remain unchanged. Error class is retained; the
  message now identifies the logical Agent limit rather than an FSM step limit.

This correction may allow more work than the old accidental FSM cutoff, or stop
an approval-heavy run previously able to reset its session counter. Deploy at a
quiescent Runtime boundary; do not hot-swap an active process. Application owners
must assess actual iteration needs after the counting bug is fixed. Increasing
example limits is not part of this change.

## Verification scope

Regression tests cover nine Tool rounds plus final call ten, streaming, a real
RubyLLM retry through stubbed HTTP, many Tools in one response, exact cutoff,
fresh execution, approval and fresh Runtime restoration, recovered provider/Tool
outcomes, legacy metadata, zero and invalid limits. Generic Engine tests cover
automatic loops, stale events and unchanged default session limits. Live LM Studio
acceptance and its independent peg-native parsing failure remain separate gates.
