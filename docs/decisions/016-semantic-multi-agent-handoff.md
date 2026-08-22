# ADR-016: Semantic Multi-Agent Handoff and Runtime-local Ownership

## Status

Accepted.

## Context

The previous Multi-Agent Handoff implementation encoded routing through a
special Tool name and sentinel Tool result. That mechanism could identify a
Target Agent, but it conflated control-plane routing with ordinary Tool execution
and did not define sufficient Context-transfer, provenance, ownership, or
next-turn semantics.

Handoff is also semantically different from Agent-as-Tool delegation. Delegation
returns control to the parent coordinator. Handoff transfers active
responsibility to another Agent.

ADR-012 remains authoritative for the canonical execution log and per-call
Context Policy/Manifest pipeline. ADR-013 remains authoritative for persistent
Journal-backed Knowledge. This ADR defines the Agent-boundary transfer semantics
without replacing either decision.

## Decision

### 1. Handoff is an explicit Source-to-Target semantic edge

`Phronomy::MultiAgent::Handoff` binds concrete live `source_agent` and
`target_agent` instances plus a `HandoffPolicy` and description.

Generated Tool names are private transport encoding. They are not Handoff
identity, durable routing identity, or public semantic contract.

### 2. Handoff is control-plane transfer, not an ordinary Tool effect

The LLM-facing capability is intercepted before `ToolInvocation` creation. A
valid Handoff produces a typed private `HandoffRequest` and a Source execution
terminal outcome of `:handed_off`.

No sentinel Tool result is generated. One Provider outcome may not mix Handoff
with ordinary Tool Calls or contain multiple Handoff requests.

### 3. Handoff Policy owns the Agent-boundary transfer decision

The initial transfer categories are `current_request`, `history`, `knowledge`,
and `tool_exchanges`. Application policy classifies each as `required`,
`forbidden`, or `selectable`, with an include/exclude default for selectable
categories.

Required and forbidden decisions cannot be overridden by the Source Agent.
Source selection is bounded to the effective Source Context represented by the
current Manifest.

### 4. Context selection machinery is shared, but policy authority is not

Context and Handoff use shared `Agent::Selection::Candidate`, `Unit`,
`Constraint`, and validation machinery. Tool Call/Tool result dependency closure
is preserved as one selection unit.

Handoff Policy answers what may cross the Agent boundary. Target Context Policy
remains the final authority for what enters each Target LLM call. Transferred
Handoff Context is therefore converted to selectable Target Context candidates
before Target Context Policy runs.

### 5. Handoff Context is immutable, reference-only transferred material

Selected Source content is materialized into an immutable private
`HandoffContext`; Target execution does not depend on later dereferencing mutable
Source state. Source and Target may use different Persistence adapters.

Transferred material is not automatically adopted into Target Journal or
persistent Knowledge. Provenance records the original Agent/record/execution/LLM
call/Tool call where available, plus a multi-hop transfer path.

### 6. Active responsibility is Runtime-local

One `main_agent` instance anchors one Multi-Agent coordination lifetime. The
Runtime/EventLoop is the sole mutation authority for `active_agent` and active
Handoff Context. The current Target remains active across user turns and across
Runner-facade recreation while the same main Agent instance and Runtime live.

Concurrent turns for the same coordination lifetime are rejected by Runtime
admission rather than racing active-Agent transitions.

This coordination state is not durably rehydrated. Runtime/process reset starts
again at `main_agent`; historical `execution_handed_off` audit facts do not imply
restored active-Agent ownership.

### 7. Public Runner cutover is a clean break

The public coordinator is `Phronomy::MultiAgent::Runner.new(main_agent:,
handoffs:)`. `Phronomy::Agent::Runner`, `agents:`, `routes:`, and the old Agent-owned
Handoff Tool registry are removed without compatibility aliases.

## Consequences

Applications gain explicit Handoff semantics, bounded multi-hop continuation,
Context transfer with provenance, and predictable next-turn ownership.

The framework has a stronger separation between control-plane operations and
ordinary Tools, but applications migrating from the old Runner must update their
configuration code. Active-Agent continuation remains intentionally process-local
until a future decision defines a durable coordination identity and rehydration
contract.
