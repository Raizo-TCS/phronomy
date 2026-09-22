# ADR-053: SharedState Coordination Ownership

## Status

Accepted on the architecture refactoring branch, 2026-09-22.
This resolves the deferred SharedState ownership decision in
[046-agent-responsibility-layout-and-shared-records](046-agent-responsibility-layout-and-shared-records.md).

## Context

SharedState creates an invocation-local findings store, equips several Agent
definitions with read/write Tools, invokes members in declaration order, repeats
cycles until a configured limit, and aggregates the findings. It is not an
individual Agent's state container or execution coordinator. These responsibilities
belong to MultiAgent, alongside the other multi-Agent coordination patterns.

Its implementation also mixes cycle orchestration with individual member calls,
and researcher instrumentation with the bodies of injected Tool definitions.
Moving a file alone would leave those abstraction levels mixed.

## Decision

1. Move the implementation to `multi_agent/shared_state.rb`, exposing the
   Experimental `Phronomy::MultiAgent::SharedState` and its nested `KnowledgeStore`.
   Remove `Phronomy::Agent::SharedState` without an alias on this branch, following
   the coordination ownership precedent in
   [034-handoff-runner-coordination-ownership](034-handoff-runner-coordination-ownership.md).
   Update examples, RBS and the [migration guide](../migrations/shared-state-multi-agent.md)
   together. Ordinary consumers continue to `require "phronomy"`.
2. Express invocation as termination validation, store creation, member
   coordination and result aggregation. Express each cycle as ordered member
   invocation followed by stopping decisions. Build the two injected Tool
   definitions in named private methods. Keep these responsibilities in the same
   class; no new execution manager or general coordination abstraction is needed.
3. Preserve the DSL, method parameters, prompt text, Tool descriptions/schema,
   cooperative execution mode, original Tool aliases, result shape and exceptions.
   Members remain sequential; findings from an earlier member are visible to the
   next member in the same cycle. `terminate_when` still takes precedence over
   timeout after each complete cycle, and timeout does not interrupt a member.
4. Preserve the generated Agent definition ID prefix
   `Phronomy::Agent::SharedState::Instrumented/` and instrumentation version 1.
   This string is semantic identity, not a Ruby constant lookup or old-name alias.
   Namespace placement alone must not change the wrapped definition revision.

## Consequences and limits

This is a breaking rename of an Experimental public API, including the nested
store class name. The Stable/Beta API snapshot does not enumerate SharedState;
an unchanged snapshot does not establish complete public API compatibility.

The store is still newly created for each invocation and is not durable shared
Agent state. The coordinator adds no resume, cancellation, asynchronous execution,
transaction, F4 or X0 guarantee. `invoke` still accepts `config:` without
forwarding it to the member calls. Revising that behavior is a separate change.

No persistence schema or saved-record migration is introduced. Individual Agent
persistence keeps its existing rules; this move does not make the in-memory
coordination lifetime resumable. The method extraction slightly increases source
length and does not eliminate unrelated dependency cycles.

Storage domain responsibilities and Workflow terminal ownership remain separate
work items. This decision does not reopen the completed ExecutionCoordinator split.

## Verification obligations

Verify new namespace loading, absence of the old alias, repeated eager-load
identity and no Runtime startup during loading. Exercise existing coordination,
stopping, aggregation, Tool alias and definition identity tests. Check the full
and integration suites, offline examples, RBS, annotations, style and built gem
contents, including removal of the old implementation path. Record executed
results and untested environments separately in the delivery review.
