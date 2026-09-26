# ADR-040: Configuration Default Composition

## Status

Accepted on the architecture refactoring branch.

Amends concrete-default ownership in
[038-responsibility-based-source-layout](038-responsibility-based-source-layout.md)
and [039-runtime-configuration-lifecycle-ownership](039-runtime-configuration-lifecycle-ownership.md).
Their loading, public compatibility, and Runtime reset rules remain in force.
The provider-call and framework-owned async boundary in
[027-llm-adapter-provider-boundary](027-llm-adapter-provider-boundary.md) is unchanged.

## Amendment: neutral runtime settings

[060-runtime-settings-and-application-configuration](060-runtime-settings-and-application-configuration.md)
amends configuration placement and Engine access: application configuration and
global accessors belong to `runtime_composition/`, while `configuration/` owns
only neutral `RuntimeSettings`. Concrete defaults remain composition-owned;
public configuration and Runtime reset behavior remain unchanged.

## Context

`Configuration` holds settings read by Engine and other framework components.
Its constructor also selected and instantiated `LLMAdapter::RubyLLM` and
`Tracing::NullTracer`. The adapter base uses Runtime for default asynchronous
execution, while Runtime reads configuration. Tracing also reads configuration.
Concrete default selection therefore created reverse implementation references
from settings to their consumers.

Simply moving the constructor into another file that reopens `Configuration`
would not separate these responsibilities. Changing `Configuration.new` to
produce unset components, replacing it with a different application factory,
or sharing prebuilt defaults would change existing behavior.

## Decision

1. `configuration/` owns setting values, validation, global access, replacement,
   and scoped overrides. It must not select concrete adapters, tracers, or Runtime
   implementations. Scalar defaults remain in `Configuration#initialize`.
2. `runtime_composition/configuration_defaults.rb` selects `RubyLLM` and
   `NullTracer` with explicit constant references in zero-argument factories.
   It binds these factories through `Configuration.install_default_factories`
   during application loading. This method is `@api private`; it is a narrow
   internal boot operation, not a configurable provider registry or extension SPI.
3. `Configuration` owns the factory slots it consumes. Binding freezes those
   slots once. The inherited constructor uses the same binding for subclasses,
   avoiding class-instance-variable inheritance differences. The constructor
   invokes each factory for each configuration; it does not cache instances or
   lazily replace attributes on access. Applications still use `tracer=` and
   `llm_adapter=` to supply their instances.
4. `lib/phronomy.rb` explicitly loads the binding file after Zeitwerk setup and
   before exposing global configuration access or loading lifecycle extensions.
   The binding file is excluded from automatic namespace inference, as is the
   existing Runtime coordination file. It introduces no composition namespace.
   Merely binding factories does not create global configuration, instantiate
   components, or start Runtime. Arbitrary internal file loading remains outside
   the public application-loading contract.
5. Preserve the zero-argument constructor, fresh default instances, subclass
   behavior, shallow scoped restoration, explicit overrides, Runtime laziness,
   reset ordering, exception propagation, and previous grace-period handling.
   No adapter SPI, async method, provider behavior, transport policy, public
   signature, or persisted format changes in this step.

The binding in decision 2 is limited to default component construction. It does
not add a Runtime reset registration hook or amend ADR-039's reset algorithm.

## Dependency interpretation and remaining work

This is dependency inversion at the component selection boundary. The settings
owner defines and consumes factory slots; application composition supplies their
implementations. Settings can be instantiated with local factories without
loading Engine, adapters, or tracing. No dynamic constant lookup is used to
hide implementation references.

The runtime call from `Configuration#initialize` through the factory to a
concrete constructor still exists. Static reference graphs do not generally
follow this injected call; reports must distinguish source references from
runtime factory invocation. Construction does not call `Runtime.instance`:
the adapter's default pool is acquired later when an async method is called.
The previous graph cycle was not infinite constructor recursion.

At this decision's implementation point, `LLMAdapter::Base` still owned the
framework async wrappers and referenced Runtime.
[ADR-059](059-backend-contracts-and-async-clients.md) subsequently moves that
dependency to the private `LLMAdapter::AsyncClient`.
Runtime, pools, tracing, and Agent retain other dependencies and cycles. This
step does not claim complete provider independence or an acyclic repository.

## Verification obligations

- Guard that configuration source does not reference Runtime, LLMAdapter, or
  Tracing, and demonstrate settings construction with supplied local factories
  without those implementations or application composition loaded.
- Verify binding and normal/eager loading do not instantiate global settings
  or start Runtime, including after preloading configuration definitions.
- Preserve fresh defaults, subclass construction, explicit overrides, scoped
  component identity restoration, and reset behavior on failed Runtime cleanup.
- Run the adapter contract/routing tests, configuration and Runtime lifecycle
  tests, integration tests, and repository style/type/annotation gates.
- Preserve the API snapshot without regeneration and report the private boot
  method separately; do not claim that the snapshot covers Configuration or
  every framework singleton operation.
- Compare dependencies against the applied baseline with the same analyzer and
  identify the unapplied candidate's exact source tree.
