# ADR-039: Runtime and Configuration Lifecycle Ownership

## Status

Accepted on the architecture refactoring branch.

Amends the configuration ownership in
[038-responsibility-based-source-layout](038-responsibility-based-source-layout.md).
Its loading rules, direct-root allowlist, and compatibility requirements remain
in force.

## Context

`Phronomy.reset_runtime!` shuts down the default Runtime and replaces global
configuration only after successful Runtime cleanup. Its configuration grace
period preservation is application lifecycle coordination between two owners.
Placing this operation in `configuration/global_configuration.rb` made ordinary
configuration readers point to a file that also controlled Runtime shutdown.

Engine reads configuration for pool sizes, logging, and shutdown defaults.
Configuration access must not also own the reverse Runtime lifecycle operation.
Moving that operation into `common/` would give common definitions an Engine
dependency. Moving it into an Engine primitive would mix global configuration
replacement with Runtime execution mechanics.

## Decision

1. Keep configuration values, concrete defaults, global access, replacement,
   and scoped overrides in `configuration/`.
2. Place `Phronomy.reset_runtime!` in
   `runtime_composition/global_runtime.rb`. This responsibility group coordinates
   Runtime and configuration. Engine and configuration implementation files
   must not require the composition file or the application entry point.
3. Keep this namespace-reopening file outside Zeitwerk name inference. Load it
   explicitly from `lib/phronomy.rb` after global configuration access is
   available. Do not introduce a `Phronomy::RuntimeComposition` constant,
   compatibility alias, registration hook, or alternate reset API.
4. Preserve the reset method body and signature. In particular, Runtime cleanup
   happens before configuration replacement; an error from cleanup propagates
   without resetting configuration. Preserve the timeout default, previous
   grace value handling, laziness of the default Runtime, and return value.

## Dependency interpretation and remaining work

The direct configuration-to-Runtime reference moves to the composition owner.
Ordinary configuration readers still resolve to the configuration accessor
file. Reference analysis must resolve each `Phronomy` operation to its actual
method definition, not assign every operation to an arbitrary namespace file.

This step does not remove the separate cycle formed by concrete defaults:
`Configuration` constructs `LLMAdapter::RubyLLM`, its base supplies asynchronous
execution through `Runtime`, and Runtime reads global configuration. The
default tracer is also concrete. Preserving `Configuration.new` behavior while
separating default construction requires a separate design decision. Do not
hide these references with dynamic constant lookup or claim that the entire
configuration/Engine cycle has disappeared.

## Verification obligations

- Guard that configuration files can be loaded without loading Engine or
  Runtime composition, exposing the reset operation, or directly referencing
  Runtime. This loading check does not promise a new public partial-loading API.
- Verify ordinary application loading exposes the existing reset API and eager
  loading creates no synthetic composition namespace.
- Compare production method definitions against the preceding layout candidate;
  this extraction changes no method bodies.
- Run the existing configuration, Runtime lifecycle, shutdown participant,
  compatibility, and integration tests and repository style/type gates.
- Report remaining cycles with the same analyzer and distinguish the unapplied
  candidate source tree from the applied baseline commit.
