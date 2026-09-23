# ADR-044: Agent Default and One-Shot Composition

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-21
**Refines**: [038-responsibility-based-source-layout](038-responsibility-based-source-layout.md)
and [040-configuration-default-composition](040-configuration-default-composition.md)

## Problem

`Agent::Base` selected the concrete default with `Persistence.in_memory`.
`Agent.run_once`, defined beside Agent lifecycle namespace loading, also selected
and constructed Persistence. Both files therefore depended on the higher-level
Persistence composition API, but for different reasons.

Default selection is an injected construction dependency of Agent execution.
One-shot execution is itself a composition API. Treating both as lower-level
Agent execution obscured those responsibilities. Replacing one-shot storage with
the configured shared Persistence would change isolation and existing behavior.

## Decision

1. Agent owns the private `Agent::DefaultPersistence` construction contract. A
   zero-argument factory is bound once and frozen during application loading.
   `Base` invokes it only after the explicit `persistence:` and configured
   `configuration.persistence` values have both been excluded, preserving their
   existing truthy fallback order. It neither caches the constructed instance
   nor writes it to configuration. Subclasses consume the same binding.
2. `runtime_composition/agent_defaults.rb` selects `Persistence.in_memory` in
   that factory. Binding does not invoke it, create settings, or start Runtime.
   The binding is not a public plugin registry, an alternative application
   configuration mechanism, or a new Runtime service locator. Runtime and
   configuration resets do not replace or reinstall it.
3. `agent/composition/run_once.rb` owns the actual `Agent.run_once` definition.
   It remains `Phronomy::Agent.run_once`, with the same parameters, forwarding,
   result, and exception behavior. It constructs fresh ephemeral Persistence on
   every call even when global Persistence is configured. It does not consume
   Base's fallback factory. Rejecting simultaneous `on_event:` and a block still
   occurs before storage or Agent construction.
4. `agent/api/agent.rb` retains `StreamEvent` and lifecycle extension loading.
   It has no delegate to the higher-level one-shot implementation. The
   application entry explicitly requires the namespace extensions, factory
   binding, and one-shot method definition after Zeitwerk setup and global
   configuration access installation. The composition directory and binding
   file are ignored by Zeitwerk because they wire existing constants rather
   than introduce matching public namespaces. Agent execution never requires
   the application entry or either composition file.
5. Normal application loading, first constant access, repeated requires, and
   eager loading retain constant identity and exactly one lifecycle extension.
   Explicit namespace loading also handles the internal unbound factory
   contract having been loaded first. Arbitrary partial loading of framework
   implementation files remains outside the public application-loading API.

## Compatibility and guarantees

The public constructor and one-shot API, event callback paths, stored records,
transaction boundaries, Agent ownership, and shutdown behavior are unchanged.
The existing API snapshot is not regenerated. It does not cover the `run_once`
singleton signature, which is checked explicitly along with real invocation,
creation-time context/Knowledge, and both forms of event listener.

The factory's exception propagates unchanged through the existing Agent
creation/ownership handling. Classified failures such as ConfigurationError
release the reservation; unclassified failures such as IOError retain the
existing fail-closed recovery-required reservation. Do not make every factory
failure retryable as a side effect of moving default selection. Existing
explicit Persistence injection works without invoking the factory.

This is source dependency inversion, not removal of the runtime construction
call: `Base` still invokes the bound factory when a default is needed. The
one-shot implementation still depends explicitly on Agent and Persistence.
Both selecting and invoking the one-shot composition remain above execution.
The private factory slot is immutable after boot; returned Persistence
instances remain separate, mutable storage instances.

No F1 uncertain-commit reconciliation, F4 recovery guarantee, external-effect
rollback, or exactly-once guarantee is added. The previous in-memory durability
limits remain. Runtime retains created Agents according to existing ownership
rules; moving `run_once` does not introduce new cleanup or lifetime behavior.

## Dependency interpretation

Remove `agent -> persistence/api` and `agent/api -> persistence/api`.
Add explicit composition dependencies from `runtime_composition` to Agent and
Persistence and from `agent/composition` to Persistence. One-shot composition
also calls the injected Agent definition's `create` method; namespace declarations
and injected calls do not count as static constant-reference edges. The
`Tools::Agent` call to `Agent.run_once` now targets its actual definition in
`agent/composition`. Treat the new Agent composition directory as B1; it is
not a new Ruby namespace.
The internal Base-to-factory reference remains within Agent's directory.

The remaining reverse dependency `agent -> workflow/execution` is the separate
worker-input classification change (E). This change does not resolve all
directory/file cycles, Storage's domain-specific repository names, or the
Engine FSM terminal persistence responsibilities.

## Verification

Cover fallback precedence, fresh instances and subclass construction, resets,
classified failure/retry and unclassified fail-closed behavior, supplied-factory
independence, normal/preloaded/eager
loading, one-shot isolation from global Persistence, argument/result/exception
identity, context/Knowledge forwarding, callback conflict ordering, and both
event listener forms. Run existing Agent ownership/event tests, default and
integration suites, style, API snapshot, RBS, and annotation gates. Verify
examples against the changed core without modifying their public call sites.
