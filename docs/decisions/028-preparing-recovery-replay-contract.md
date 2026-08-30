# ADR-028: Replay-safe recovery for durably admitted `:preparing` Agent executions

Status: Accepted

## Context

ADR-018 defines Agent execution resumption as continuation of the same logical
`execution_id` from durable recovery state when there is no unresolved semantic
operation that prevents safe continuation. The implementation already persists a
new `AgentExecution` in `status: :preparing, phase: :preparing` before input
filters, `before_llm_input`, Context Policy, and Manifest finalization run.

Before this decision, process loss in that window left a durable active execution
with no automatic continuation path.

## Decision

A `:preparing` execution may be resumed automatically only when the framework
durably recorded `preparation_replayable == true`. Missing, false, or unsupported
values fail closed. The recovered continuation keeps the same `execution_id`.

The preparation region is **replay-safe, not deterministic**. Input filtering,
`before_llm_input`, Context Policy, retrieval, and other preparation work may be
executed again after process loss. Applications must ensure those callbacks are
safe under at-least-once execution. The framework does not require repeated
preparation to produce byte-identical results.

Before Manifest finalization, preparation results may be recomputed. After the
Manifest is durably committed, the Manifest is the authority and existing
post-Manifest recovery rules apply.

### Durable application context

`config` remains a runtime/application Hash and is not generally durable. An
Application value that affects preparation semantics and must survive restart is
placed under one reserved key:

```ruby
config: {
  durable_context: {
    "tenant" => "A",
    "search_profile" => "legal"
  }
}
```

`config[:durable_context]`, when present, must be a Hash accepted by
`Phronomy::CanonicalJSON`. The framework performs a Canonical JSON round trip
before execution admission and uses the detached immutable snapshot for both the
initial run and any recovery replay. `durable_context: nil` and non-Hash values
are rejected before an `AgentExecution` is created. Missing and explicit `{}` are
distinct.

The snapshot is stored in the Content Store and the execution retains only
`durable_context_ref`.

### Conservative replay eligibility

This change intentionally does not add a new arbitrary raw-input serialization
format. Current initial admission stores `extract_message(input)` as text, while
filters and instruction construction may inspect the original Ruby input.
Therefore automatic `:preparing` replay is enabled only for String invocation
inputs. Non-String inputs fail closed after process loss at this phase.

Automatic preparation replay is also disabled when the framework can see a
Runtime-only semantic dependency that it cannot reconstruct, including:

- Multi-Agent handoff/routing wiring;
- a custom Agent invocation approval policy;
- invocation-context approval/redaction/token-budget policy values.

These conditions are represented by the single durable boolean
`preparation_replayable`; the framework does not persist those Runtime objects.
A true value records that no framework-known blocker was present; it does not
replace the Application replay-safety contract for callbacks or custom config.

Applications that use other ordinary `config` entries to influence preparation,
Provider-adapter, Tool, or other continuation semantics are responsible for moving
restart-required values into `config[:durable_context]` and reading them from that
sub-Hash after recovery.

### Agent definition compatibility

Existing `agent_definition_id` / `agent_definition_version` load validation
continues to guard runtime definition compatibility. Applications must increment
the Agent definition version when a change to filters, hooks, Context Policy, or
other preparation behavior is not recovery-compatible.

## Non-goals

This decision does not add:

- recovery of caller `Task` objects;
- durable Multi-Agent active routing or Handoff Context;
- a durable execution-query API;
- a new Recovery event;
- Content Store garbage collection;
- Workflow checkpoint changes;
- deterministic replay of Application callbacks.

## Consequences

Direct, replay-safe String invocations can continue the same durable logical
execution after process loss in the initial preparation window. Unsupported or
ambiguous cases remain fail-closed rather than being guessed or silently
abandoned.
