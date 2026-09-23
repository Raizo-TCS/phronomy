# ADR-034: Handoff Runner Coordination Ownership

## Status

Accepted for the H1 step on `refactor/architecture`, 2026-09-18.
The subsequent Handoff contract and persistence separation is deferred.

## Scope of supersession

This amends the Runner placement/public namespace in
[030-agent-handoff-domain-and-durable-responsibility](030-agent-handoff-domain-and-durable-responsibility.md)
and the domain map in
[031-durable-multi-agent-coordination](031-durable-multi-agent-coordination.md).
All other durable Handoff semantics remain in force.

## Context

HandoffRunner validates a graph of concrete Agents, selects the active Agent,
invokes or resumes exact executions, follows multiple transfers, and scopes
cancellation/result lookup to a specified chain. Those responsibilities span
Agents. They differ from an individual Agent's execution, Journal and Context.

Calling Handoff from an Agent does not make that whole coordination lifetime an
Agent implementation detail. Updating the Source and routing state in one
transaction also does not require them to occupy one module.

The Runner and TeamCoordinator share the Runtime-local AdmissionRegistry. Keeping
the Runner inside Agent creates an Agent-to-MultiAgent concrete dependency.
Moving only the Runner aligns ownership without generalizing the registry or
changing the existing shutdown participant contract.

## Decision

1. Move the public Runner implementation from `agent/handoff_runner.rb` to
   `multi_agent/handoff_runner.rb` and expose
   `Phronomy::MultiAgent::HandoffRunner`.
2. Remove `Phronomy::Agent::HandoffRunner` without a compatibility alias on the
   refactoring branch. Migrate API documentation, RBS, snapshot and consumers
   together. See the [migration guide](../migrations/handoff-runner-multi-agent.md).
3. Retain `Agent::Handoff`, `HandoffPolicy`, Context/Request/State and Agent
   terminal/persistence integration during H1. Qualify the Runner's dependencies
   explicitly. This mixed placement is an intermediate state.
4. Keep AdmissionRegistry in MultiAgent. The admission key, exception classes,
   successful-call release and Runtime shutdown participation are unchanged.
5. Preserve method parameters/results, record formats, main-Agent anchor,
   deterministic Target IDs, transaction boundaries, exact recovery and scoped
   cancellation. H1 introduces no new execution or shutdown manager.

## Consequences and limits

Agent no longer directly names a MultiAgent implementation in production source.
The Runner's existing Tracing dependency now belongs to the MultiAgent directory.
Module-edge totals and large strongly connected components need not decrease:
this step changes responsibility placement, not the underlying algorithm.

Agent still interprets Handoff/Team coordination metadata. This logical coupling
is not removed merely because a directory edge disappears.

Later work must separate Request construction, Coordinator selection, Context
conversion, transaction participation and purge/recovery constraints before
moving the remaining Handoff-specific types and persistence rules. That work must
preserve one transaction for Source termination plus responsibility transfer and
for Target termination plus routing stabilization. It must not promote transferred
Context into permanent Target Journal/Knowledge or depend on post-commit callbacks
for coordination correctness.

## Verification obligations

The new public constant must load with Zeitwerk and match its RBS/API snapshot;
the old constant must not remain as an alias. Existing Handoff, multi-hop,
cancellation/recovery, shutdown and SQLite reconstruction scenarios must pass.
API guards must distinguish `MultiAgent::HandoffRunner` from the removed exact
constant `MultiAgent::Handoff`.

The implementation delivery records test results separately; this ADR does not
assert that unexecuted live-LLM or database-server tests passed.
