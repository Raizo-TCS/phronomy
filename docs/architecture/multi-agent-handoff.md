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
[ADR-016](../decisions/016-semantic-multi-agent-handoff.md).

## 2. Public API

```ruby
handoff = Phronomy::MultiAgent::Handoff.new(
  source_agent: triage,
  target_agent: billing,
  description: "Transfer billing responsibility",
  policy: policy
)

runner = Phronomy::MultiAgent::Runner.new(
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

## 9. Next-turn continuity and durability

The same `main_agent` instance plus the same Runtime define one coordination
lifetime.

Within that lifetime, the active Target remains active on later turns and across
Runner-facade recreation. Runtime admission rejects racing concurrent turns for
the same coordination lifetime.

Active routing is **not durably rehydrated**. Runtime/process reset starts a new
coordination lifetime at `main_agent`. Historical Handoff audit facts do not
reconstruct active Target ownership.

## 10. Cancellation and tracing

Handoff does not create a separate cancellation domain; active Agent execution
uses normal Agent semantics.

One Runner user turn is automatically observable as `multi_agent.turn`. Source
and Target Agent/LLM/Tool logical operations keep their own automatic spans and
semantic IDs. Handoff adds no generic correlation identity or cross-Runtime
parent-span guarantee.

See [Tracing](tracing.md).

## 11. Safety and removed API

`Phronomy::MultiAgent::Runner::MAX_HANDOFFS` bounds transfers in one user turn.

Not current contracts:

- sentinel Handoff Tool results;
- `Phronomy::Agent::Runner`;
- `agents:` / `routes:` Runner configuration;
- Agent-owned Handoff Tool registration;
- generated Tool-name identity;
- blanket Source history/Knowledge copying.
