# Phronomy — Semantic Multi-Agent Handoff

## 1. Overview

Phronomy Multi-Agent Handoff transfers active responsibility from one live
Agent instance to another. It is a control-plane operation, not an ordinary Tool
result protocol.

```text
User input
   |
MultiAgent::Runner
   |
Source Agent -- semantic Handoff --> Target Agent
                                  |
                             final answer
```

Handoff is distinct from Agent-as-Tool delegation. Delegation returns control to
the caller after the delegated work completes. Handoff changes the active Agent
for the coordination lifetime.

The normative architecture is ADR-016. This document describes the current
public API and implementation model.

## 2. Public API

### 2.1 Handoff edge

A Handoff binds concrete live Source and Target Agent instances.

```ruby
handoff = Phronomy::MultiAgent::Handoff.new(
  source_agent: triage,
  target_agent: billing,
  description: "Transfer billing responsibility"
)
```

The optional `policy:` argument is a `Phronomy::MultiAgent::HandoffPolicy`.
There is no Agent-class `handoffs` DSL and no Agent-owned runtime Handoff Tool
registry.

### 2.2 Runner

```ruby
runner = Phronomy::MultiAgent::Runner.new(
  main_agent: triage,
  handoffs: [triage_to_billing, billing_to_triage]
)

result = runner.invoke("My invoice is wrong")
result[:output]
result[:agent]
```

`main_agent` anchors one Runtime-local coordination lifetime. The active Target
remains active across later user turns and across recreation of only the Runner
facade while the same main Agent instance and Runtime remain alive.

The old `Phronomy::Agent::Runner`, `agents:`, and `routes:` API is removed.

## 3. LLM-facing transport versus semantic Handoff

Phronomy exposes each outgoing Handoff to the Source LLM as a generated Tool
schema so the model can request a transfer. That generated Tool name is private
transport encoding only.

When the Provider returns that Tool Call, Phronomy intercepts it before ordinary
Tool execution and creates a typed private `HandoffRequest`. No sentinel Tool
result is produced and no ordinary `ToolInvocation` is executed for the Handoff.

One Provider outcome may not mix a Handoff request with ordinary Tool Calls or
contain multiple Handoff requests.

## 4. Handoff Policy

Handoff Policy controls what material from the effective Source Manifest may
cross the Agent boundary.

The categories are:

```text
current_request
history
knowledge
tool_exchanges
```

Each category is declared as `required`, `forbidden`, or `selectable`.
Selectable categories also define an include/exclude default.

```ruby
policy = Phronomy::MultiAgent::HandoffPolicy.define do
  required :current_request
  selectable :history, default: :include
  selectable :knowledge, default: :exclude
  selectable :tool_exchanges, default: :include
end
```

Required and forbidden rules cannot be overridden by Source selection intent.
Handoff selection is bounded to the finalized Source `LLMInputManifest`.

## 5. Context Policy boundary

Context Policy and Handoff Policy have different authority.

```text
Source ContextPolicy
  -> finalizes one Source LLMInputManifest

HandoffPolicy
  -> selects what may cross Source -> Target

Target ContextPolicy
  -> decides what enters one Target LLM call
```

Transferred Handoff material becomes selectable Target Context candidates before
the Target Context Policy runs. It is not automatically appended to Target
Journal or persistent Knowledge.

## 6. Conversation groups and Tool exchanges

ACS-04 Context Policy uses typed `ContextPolicyInput` conversation groups.
An assistant Tool Call and the Tool-role message(s) answering it are one
indivisible conversation group.

When `ContextAssembler` realizes a `ContextPlan`, Manifest segments receive
Framework-owned semantic metadata:

```text
context_policy_semantic_category
context_policy_conversation_group_id   # conversation only
handoff_policy_category                # when an explicit Handoff category is known
```

The semantic category identifies whether a segment came from the Context Plan's
`instruction`, `knowledge`, or `conversation` collection independently of the
item's lower-level `kind` value. This is important for Application-defined
conversation kinds. The semantic-category marker is preserved through private
Handoff Context so the Target `ContextPolicyInputBuilder` can reconstruct the
correct typed category even when the lower-level kind is Application-defined.

Canonical Tool exchange groups are additionally classified as
`handoff_policy_category = tool_exchanges`.

`HandoffProjection` groups current-format conversation segments by
`context_policy_conversation_group_id`. For finalized pre-ACS-04 Manifests it
may still read legacy `selection_unit_id` / `selection_unit_kind` metadata, but
new Context assembly does not recreate `Selection::Unit`.

## 7. Provenance

Handoff Context is immutable materialized content. Provenance records the
original Agent and, where available, Journal record, Agent execution, LLM call,
and Tool call. Multi-hop transfers append the Target Agent ID to the transfer
path while retaining the original provenance.

Source and Target Agents may use different Persistence adapters because the
selected content is materialized at the boundary rather than represented as a
live reference into Source state.

## 8. Runtime-local active responsibility

Active-Agent ownership is Runtime-local. `MultiAgent::Coordinator` owns the
active Agent and active Handoff Context for a coordination lifetime, with
Runtime/EventLoop admission preventing concurrent turns from racing that state.

This active ownership is intentionally not durably rehydrated. A process or
Runtime reset begins a new coordination lifetime at `main_agent`; historical
`:handed_off` execution facts do not reconstruct active-Agent routing.

## 9. Safety limits

`Phronomy::MultiAgent::Runner::MAX_HANDOFFS` limits the number of transfers in a
single user turn. Exceeding the limit raises `Phronomy::HandoffError`.

## 10. Removed architecture

The following are not part of the current design:

- sentinel Handoff Tool results;
- scanning Tool messages for a sentinel string;
- `Phronomy::Agent::Runner`;
- `agents:` / `routes:` Runner configuration;
- Agent-owned Handoff Tool registration;
- Handoff identity based on generated Tool names;
- current Context selection through `Selection::Unit`.

See ADR-016, ADR-012, and `spec/design/02_architecture_overview.md` for the
normative execution and Context boundaries.
