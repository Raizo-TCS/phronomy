> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# Semantic Multi-Agent Handoff

## 1. Meaning

Handoff transfers active responsibility from one live Source Agent to one live
Target Agent together with sufficient policy-bounded Context for the Target to
continue.

It is a control-plane operation, not an ordinary Tool-result protocol.

Handoff is distinct from Agent-as-Tool delegation. Delegation performs work and
returns control to the caller. Handoff changes the active Agent for the current
coordination lifetime.

Normative Handoff intent is
[ADR-030](../decisions/030-agent-handoff-domain-and-durable-responsibility.md).

## 2. Public API

```ruby
handoff = Phronomy::Agent::Handoff.new(
  source_agent: triage,
  target_agent: billing,
  description: "Transfer billing responsibility",
  policy: policy
)

runner = Phronomy::Agent::HandoffRunner.new(
  main_agent: triage,
  handoffs: [handoff]
)

result = runner.invoke("My invoice is wrong")
```

The current public Runner facade is synchronous `#invoke`. Handoff architecture
does not add async/stream APIs merely for symmetry.

## 3. Private transport

Outgoing Handoffs are represented to the Source LLM through generated Tool
schemas. The generated Tool name is private transport encoding, not Handoff
identity or public semantic contract.

Phronomy intercepts the Provider Tool Call into a typed private
`HandoffRequest`. It does not execute an ordinary `ToolInvocation` or emit a
sentinel Tool result.

## 4. Handoff Policy

`HandoffPolicy` controls what material from the effective finalized Source
Manifest may cross the Agent boundary.

```text
current_request
history
knowledge
tool_exchanges
```

Each category is required, forbidden, or selectable. Handoff selection is bounded
to the finalized Source Manifest.

## 5. Context Policy relationship

```text
Source ContextPolicy
  -> Source LLMInputManifest

HandoffPolicy
  -> what may cross Source -> Target

immutable HandoffContext
  -> request-scoped Target material

Target ContextPolicy
  -> what enters one Target LLM Call
```

Transfer does not automatically append content to Target Journal or persistent
Knowledge.

## 6. Conversation/Tool dependencies

An assistant Tool Call and its corresponding Tool-role result message(s) remain
an indivisible conversation group across the Handoff boundary.

Framework-owned semantic/category/content-format metadata is carried only through
the trusted typed Handoff boundary.

## 7. Responsibility and provenance

Transferred `responsibility` is the dynamic instruction for what the Target must
continue. `description` is the static edge/capability description. No mandatory
generic `handoff_reason` identity field is added.

Handoff Context preserves origin Agent and, where available, Journal record,
Agent execution, LLM call, and Tool call provenance. Multi-hop transfers extend
the transfer path while retaining original provenance.

## 8. Target state ownership

Handoff does not give Source authority to mutate Target canonical state. Target
state changes only through normal Target-owned execution/mutation paths.

A Target Agent execution has its own `execution_id`; Source execution identity is
provenance/audit context, not Target execution identity.

## 9. Persisted responsibility and recovery

The original main Agent ID anchors `HandoffState`; the active Agent is retained
across compatible Runtime restarts. The graph must use one Persistence instance.
Source `handed_off`, its journal/root transition, immutable HandoffContext and the
reserved Target execution ID commit atomically. The Target is admitted under
that ID only after an authoritative absence read and the usual Agent admission.
An active exact Target uses Agent Recovery; a terminal Target result is reused.
Target terminal settlement and routing stabilization share a transaction.

A new Runtime supplies the graph/current definitions again. Tool transport names
are deterministic from stable Source/Target Agent IDs and are resolved from that
graph, without a global class registry. Persisted Context is not reprojected under
current policy. Missing graph edges/definitions or a different Persistence domain
fail before semantic continuation.

`HandoffRunner#result(source_execution_id)` follows retained transfer links.
`cancel(execution_id)` records a request against that exact turn; pending absent
Targets are stopped without admission, active Targets use their existing Agent
cancellation token, terminal outcomes remain immutable. No cancellation or
observer loss rewinds active responsibility to the main Agent. Cancellation is
not compensation for external effects; unresolved X0 still needs Agent Recovery.

F1 commit response loss is resolved by exact readback. Read/decode failure is not
absence. F4 recovery requires retained storage and compatible current wiring.
`on_event` is Runtime-only; terminal results can be read without redelivery.

Current graph objects and observers are not durably rehydrated; Application
supplies compatible wiring. Source execution identity links each completed
transfer to its exact reserved Target execution, independently of later turns.
`Persistence#handoff_result(source_execution_id)` reads that turn without loading
Agent owners, graph definitions, or listeners.
