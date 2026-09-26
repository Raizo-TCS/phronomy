# ADR-060: Runtime Settings and Application Configuration

## Status

Accepted for this refactoring. Amends the configuration ownership in
[038-responsibility-based-source-layout](038-responsibility-based-source-layout.md),
[039-runtime-configuration-lifecycle-ownership](039-runtime-configuration-lifecycle-ownership.md)
and [040-configuration-default-composition](040-configuration-default-composition.md).

## Context

Engine consumes pool sizes, time thresholds, a logger and an injected tracer.
Application `Configuration` also exposes an LLM adapter, Agent input hook and
other domain options. Their correct public RBS types reveal an Engine-to-domain
path when Engine reads the whole Configuration. A two-reference baseline allowed
this old type debt through the regression gate. Weakening the types, hiding
arrows or misassigning RBS owners would not repair the dependency.

## Decision

1. `configuration/` owns private `RuntimeSettings`: neutral runtime values and
   injected logger/tracer objects, with no application-specific type references.
   Engine and automatic tracing read this limited object.
2. Application `Configuration` and the global `configuration`, `configure`,
   `reset_configuration!` and `with_configuration` operations belong to
   `runtime_composition/`. Canonical Ruby names, constructor and public RBS types
   remain unchanged. The directory is collapsed by Zeitwerk; no public
   `RuntimeComposition` namespace is introduced.
3. Configuration composes RuntimeSettings and explicitly delegates its existing
   runtime-setting accessors. It retains adapter, Agent and application options.
   RBS follows the actual Ruby owner: application declarations live under
   `sig/phronomy/runtime_composition/`, internal settings under `sig/_private/`.
4. Composition installs a lazy, typed provider returning only RuntimeSettings.
   Every read resolves the current object so reset/scoped restoration cannot
   leave Engine reading an expired configuration. Binding does not initialize
   global configuration or start Runtime. This provider is private framework
   wiring, not an application extension point or a new execution service.
5. Copying Configuration copies its settings container while retaining injected
   component identities. This preserves the previous flat object's shallow-copy
   behavior, including nested scopes, exception restoration and a first scope
   entered before global configuration exists. This change adds no thread-local
   configuration semantics or live pool resizing.
6. Remove the two-reference baseline. Require the complete Ruby + RBS union to
   pass all existing responsibility rules. Also reject settings paths reaching
   any non-common responsibility.

## Direct dependencies are evaluated by responsibility

LLM error/TokenUsage contracts are already abstract vocabulary, so routing them
through a concrete adapter would make coupling worse. Backend implementation,
schema, migration, async bridge and conformance-suite dependencies on Storage
contracts are intentional. Domain repositories translate records, guards and
backend errors and legitimately know that SPI.

Domain runners that raise StorageConflictError for ownership/revision decisions
are a separate candidate for a persistence/domain error contract. Existing
recovery distinguishes known failure from uncertain commit outcomes; introduce
such a vocabulary only with an explicit compatibility and failure-classification
design. Do not substitute a forwarding wrapper or broadly catch StandardError.

Engine's TaskResult, Runnable and FSM contracts are the execution abstractions
used by runners and async clients. A higher-level Agent facade is not a
replacement for the mechanism that implements Agent itself. Ordinary synchronous
evaluation work can use `Blocking.call_async`: LlmJudge now does so instead of
accessing Runtime's pool. Dedicated-pool cleanup, concurrency-limited orchestration
and tracing with nonwaiting admission handling retain their specialized owners.

## Verification and graph interpretation

Preserve public signature declarations, settings defaults/accessor semantics,
subclass construction, cold loading, reset/scoped restoration and runtime pool
configuration. Check scorer provider/admission failures, the full regression
suite, RBS validation and strict dependency rules. No network provider is needed
for these behavior checks.

SVG topology must show the actual declaration owners and keep all evidence,
even for display-hidden arrows. Application configuration shares the composition
directory with lifecycle/default wiring; its directory SCC may grow because
unrelated members aggregate. Report directory SCCs and Ruby file SCCs separately;
do not claim that all cycles have disappeared or that fewer arrows is the goal.
