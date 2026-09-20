# ADR-041: Feature-Owned Identity Registries

## Status

Accepted on the architecture refactoring branch.

Amends the implementation owner of the process-local identity registry in
[025-process-local-agent-ownership-and-runtime-admission](025-process-local-agent-ownership-and-runtime-admission.md).
The one-owner invariant, Runtime lifetime, public identity operations, durable
conflict defenses, and EventLoop execution admission remain in force.

## Context

Runtime instantiated Agent and Team identity registries, exposed their specific
operations, and invoked their shutdown methods directly. Agent identity
reservation interpreted Agent lifecycle and Storage exceptions inside Engine.
These are feature policies even though their lifetime is bounded by Runtime.

Moving files while preserving concrete construction, forwarding methods, or
aliases under Runtime would retain the same dependency. A process-global weak
map would also lose the required strong ownership and Runtime isolation.

## Decision

1. `Agent::OwnershipRegistry` in `agent/ownership_registry.rb` owns Agent identity
   reservation, materialization, purge, uncertain-outcome policy, and detachment.
   `MultiAgent::TeamOwnershipRegistry` in `multi_agent/team_ownership_registry.rb`
   owns Team identity and construction exclusion. Feature callers use these
   components directly. The old Runtime registry constants and forwarding
   methods are removed; they were internal and receive no compatibility aliases.
2. Each registry lazily registers itself under its class key through Runtime's
   existing internal shutdown participant contract. Candidate construction has
   no side effects. Concurrent registration returns one authoritative instance
   per Runtime. Runtime strongly retains it; neither GC nor execution completion
   releases an identity. Registration after closure is rejected even for an
   existing key.
3. `Runtime#__shutdown_participant(key:)` only looks up an existing participant,
   including during/after shutdown. It does not create one or admit work.
   Registry `for(runtime)` reuses it; each registry's gate rejects create/load/
   purge admission after closure. `existing_for(runtime)` supports `get` without
   creating a registry. Admitted transitions may finish through the retained
   instance after closure. Lookup is not an admission bypass.
4. Participants implement `begin_draining` and `wait_until_idle(deadline)`.
   Runtime closes every gate under its lifecycle lock, including on EventLoop
   failure, before waiting outside that lock with one absolute monotonic deadline.
   Closure must be short, idempotent, and must not call Runtime. For identity
   registries, idle means no active construction/purge transition, not no live
   objects. Stable recovery-required entries do not prevent shutdown.
5. Add the optional `after_runtime_shutdown` operation. Runtime invokes it outside
   its lifecycle lock only if all participant waits succeed, no participant hook
   has failed, EventLoop's idle/join checks pass without cancellation timeout,
   and pools/timers shut down successfully. Existing participants without the
   hook remain valid. The hook must be idempotent, short, and perform no I/O;
   its return value is ignored. Agent detachment and Team directory clearing
   implement this protocol. Runtime does not know their concrete classes.
6. A finalization exception does not skip later participants. Cleanup is then
   incomplete, the first failure is retained, and default Runtime replacement
   is prohibited. Completed releases are not rolled back. Repeated shutdown
   returns the cached result rather than rerunning partial finalization.
7. Purge completion/abort/uncertainty updates the Agent object before publishing
   the corresponding registry state, under the same registry mutex. These
   internal Agent hooks only update local fields and cannot call Runtime or
   perform I/O. Shutdown cannot observe a stable transition and detach the
   Agent before that object's transition has finished.

## Guarantees and limits

| Subject | Property and provider | Failure scope / X0 | Result |
|---|---|---|---|
| Mutable Agent identity in one Runtime | At most one live owner per ID, reserved by Agent::OwnershipRegistry before materialization | Normal operation, F0 known failures, and F2 conflicts; X0 not crossed by the registry | YES within this Runtime; no cross-process exclusion |
| Uncertain Agent create/purge | Existing recovery-required policy retains the reservation | F1 durable outcome uncertainty, possibly with F0; no new X0 guarantee | YES for fail-closed local reservation; NO claim of outcome reconciliation |
| Old Agent references at Runtime replacement | Registry finalization detaches references before a completed reset | Normal shutdown and F0/F3 stop failures; X0 not managed here | CONDITIONAL on cleanup completion; failed/incomplete cleanup retains the Runtime |
| Durable facts after Runtime/process loss | Existing Persistence and recovery contracts | F4; X0 remains separate | No new guarantee; confirmed durable state and external effects are not rewritten by this change |

Team's existing conflict, Persistence identity, and construction-failure behavior
remain unchanged; Agent-specific recovery semantics are not imposed on Team.
No record format, transaction domain, public API, RBS shape, adapter SPI, or
worker mechanism changes. Runtime construction/shutdown of an unused instance
must not cause additional Agent, MultiAgent, or Storage loads; application-entry
bootstrap is measured separately.

EventLoop still owns Agent execution state/admission and Workflow-specific
control. Runtime's execution-owner and admission queries remain until a separate
execution-service extraction. This step does not make Engine feature-neutral.
Static graphs also do not follow the dynamic participant callbacks: the feature
implementation still runs through Engine's generic shutdown contract.

## Verification obligations

- Concurrent registration/materialization, exact-instance get/load, duplicate
  create rejection, incompatible class/Persistence checks, and purge behavior.
- Lookup without registration, closed admission on shutdown and EventLoop
  failure, admitted construction completion, and incomplete-cleanup retention.
- Finalization after quiescence, outside the lifecycle lock, with all later
  participants visited after an exception and no reset after failure.
- Purge object/registry transitions cannot be observed as idle halfway through.
- Source/loading boundaries, API snapshot, RBS, annotations, and existing suites.

Tests of simulated uncertain outcomes verify reservation policy, not arbitrary
external-effect exactly-once behavior or cross-process ownership.
