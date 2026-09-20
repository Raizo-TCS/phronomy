# ADR-038: Responsibility-Based Source Layout

## Status

Accepted on the architecture refactoring branch; configuration/runtime lifecycle
ownership amended by
[039-runtime-configuration-lifecycle-ownership](039-runtime-configuration-lifecycle-ownership.md).

Amends the extraction scope of
[037-common-definition-ownership](037-common-definition-ownership.md).
Its common-ownership rule and public Error contract remain unchanged.

## Context

The application loading entry point and the direct `lib/phronomy/` directory
were distinct sources of mixed ownership. After the base Error extraction,
the entry point still defined twenty feature/shared exceptions and global
configuration operations. Thirty-nine direct Ruby files still included
Workflow implementation, execution contracts, recovery, configuration, and
general values alongside namespace declarations.

A directory's location must describe its responsibility. A public constant
under `Phronomy` does not require its implementation file to remain directly
under `lib/phronomy/`. Conversely, a shared consumer list does not make a
feature contract a general common definition.

## Decision

1. Reserve `lib/phronomy.rb` for application loading and explicit initialization
   wiring. Production implementation files under `lib/phronomy/` must not require that entry
   point. Use Zeitwerk for canonical constant loading and precise requires for
   dependencies and initialization side effects.
   The existing `testing/persistence_contract.rb` is a separately documented
   public entry point for external backend authors. It remains allowed to load
   Phronomy and RSpec, and remains excluded from production automatic loading.
   This single named exception does not exempt other files under `testing/`.
2. Allow only these direct Ruby files under `lib/phronomy/`:

   | File | Reason |
   |---|---|
   | `version.rb` | Bundler/gem metadata convention and Zeitwerk GemInflector's version-file convention |
   | `llm_adapter.rb` | Explicit namespace and extension-SPI documentation |
   | `tool.rb` | Explicit public Tool authoring namespace and documentation |
   | `vector_store.rb` | Explicit namespace and backend-SPI documentation |
   | `output_parser.rb` | Explicit parser namespace declaration |
   | `testing.rb` | Explicit test-support namespace declaration |
   | `filter.rb` | Existing Filter convenience loading entry, without feature implementation |
   | `tracing.rb` | Existing Tracing convenience loading entry, without feature implementation |

   Namespace files must not accumulate method bodies or concrete classes.
   RubyGems does not mandate this entire allowlist. Keeping these small files
   is an explicit Phronomy design/compatibility choice. New exceptions to the
   allowlist require an ownership reason and an amendment to this decision.
3. Extend `common/` with `CanonicalJSON`, `ConfigurationError`, and
   `Values::Immutable`. Preserve their canonical names, JSON representation,
   copy/freeze behavior, and exception hierarchy. The three equivalent private
   Agent copy helpers delegate to `Values::Immutable.copy`; domain-specific
   command copying and Workflow copying keep their different contracts.
4. Move the remaining implementation and exception definitions to their owners:

   | Directory | Responsibility |
   |---|---|
   | `engine/` | EventLoop/FSM communication, synchronous callback constraints, execution composition, cancellation/deadlines, runtime diagnostics, invocation and runnable execution contracts |
   | `recovery/` | Shared recovery vocabulary and execution rehydration requirement; no concrete Agent/Workflow orchestration |
   | `workflow/execution/` | Workflow DSL, context ownership, runner, and terminal persistence recovery |
   | `agent/api/` | Agent namespace operations and lifecycle extension installation |
   | `agent/lifecycle_contract/` | Agent ownership, handoff, and application stream-delivery exceptions |
   | `configuration/` | Global configuration values, defaults, accessors, replacement, and scoped overrides |
   | `runtime_composition/` | Application Runtime/configuration lifecycle coordination; separated by ADR-039 |
   | `llm_contract/` | Token usage, context-budget failures, and LLM call-boundary failures |
   | `llm_adapter/ruby_llm_patches.rb` | RubyLLM version-guarded compatibility patch |
   | `persistence/api/` | Public Persistence facade and repository composition |
   | `generation/` | GeneratorVerifier pipeline and its confidence failure |
   | `tool/contract/`, `filter/contract/`, `output_parser/contract/` | Feature-owned shared exceptions |

5. Preserve all existing Ruby constant names, class/module kinds, inheritance,
   constructors, method visibility, public signatures, and persisted formats.
   Do not add constant aliases or compatibility files at retired implementation
   paths. Ordinary application loading remains `require "phronomy"`; arbitrary
   internal file paths are not a new public partial-loading API.
6. Use existing Zeitwerk `collapse` and `push_dir(namespace: Phronomy)` facilities.
   The named nested roots are independent of their enclosing namespace. This
   retains top-level `Phronomy::WorkflowContext` beside existing nested
   `Phronomy::Workflow::Persistence` without collapsing the entire Workflow
   namespace. Load `version.rb` first to establish the non-reloadable Phronomy
   root namespace. Do not depend on facilities introduced after Zeitwerk 2.6.
7. Preserve explicit lifecycle initialization. Workflow recovery must be
   prepended during ordinary application loading. Agent event/recovery
   extensions must be installed when Agent is loaded. Keep external patching
   and global namespace reopening files outside automatic name inference.
   Production eager loading must continue to exclude RSpec conformance support.

## Dependency interpretation and limits

`Event` is an Engine communication contract, not a general-purpose common
value. The `InvalidAsync*` family belongs to synchronous FSM callback rules:
Engine and Agent use the entry-action failure as well as Workflow. Moving that
contract into Workflow implementation would introduce the wrong dependency.

`ExecutionRehydrationRequiredError` belongs to recovery even though its name
starts with Execution. It is not the timeout/cancellation outcome of fan-out
composition. `ConfigurationError` is common; `Configuration` is not. Default
configuration still constructs a concrete LLM adapter and tracer. This change
groups that existing composition but does not make it implementation-neutral.

Directory relocation does not establish that every remaining dependency is
downward or that all cycles disappear. Preserve and report actual references.
An analyzer must resolve namespace operations to their defining implementation
instead of treating the shortest namespace reopening as the owner of every
method. Do not mistake a loading entry point for the implementation it loads.

## Verification obligations

- Check the direct-root allowlist and forbid internal entry-point requires.
- Verify normal and eager loading, independent common/exception loading,
  preloaded common definitions, nested-namespace access orders, and preserved
  lifecycle extension installation.
- Exercise the supported Zeitwerk lower bound and the current locked version.
- Preserve the API snapshot and RBS without regenerating away a difference.
- Run existing execution, Workflow, Agent, persistence/recovery, integration,
  configuration, and serialization tests; run the repository style/type gates.
- Compare dependencies against the applied baseline with the same analyzer.
  Mark candidate results as unapplied and identify the exact source tree.
