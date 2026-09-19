# ADR-036: Context Contract Ownership

## Status

Accepted on the architecture refactoring branch as C1.

This decision clarifies the ownership of existing Context contracts. The
Journal/Manifest authority model in ADR-012 and the Knowledge model in ADR-013
remain in force. It does not change either model or introduce a new public API.

## Context

`ContextPolicies::Default` depends on `ContextPolicy` and `ContextPolicyInput`.
Agent execution also consumes these contracts and selects a concrete policy.
Keeping the contracts beside execution classes directly under `agent/` makes
the policy directory appear to depend back on Agent execution.

The shared vocabulary is broader than a policy base class. Policy inputs refer
to the previous `LLMInputManifest`; plans and generated items have common
validation rules; `before_llm_input` hooks exchange typed input and result
values. Moving only a base class would leave those shared contracts split
across responsibility groups.

The Manifest constructs, validates, and converts record values. It does not
open transactions or write records to a backend. Its representation therefore
belongs with the Context contracts used by both producers and consumers.

## Decision

1. Move these seven unchanged files into `lib/phronomy/agent/context_contract/`:
   - `context_policy.rb`
   - `context_policy_input.rb`
   - `context_plan.rb`
   - `context_plan_validator.rb`
   - `llm_input_manifest.rb`
   - `llm_input_build_context.rb`
   - `llm_input_patch.rb`
2. Collapse the directory with Zeitwerk, following the existing Engine layout
   mechanism. Keep the existing `Phronomy::Agent::*` definitions and canonical
   names, including nested input and Manifest value types. Add no aliases or
   `Phronomy::Agent::ContextContract` namespace.
3. Keep `ContextPolicies::Default` with the concrete policy implementations.
   Keep Context assembly, input building, candidate resolution, Runtime
   integration, hook invocation, and persistence transactions with their
   existing execution-side owners.
4. Preserve policy instance binding, the `call(input)` protocol, hook input and
   result types, and the Manifest version and encoded representation. Add no
   descriptor, registry, application registration step, or data migration.
5. Treat the contracts and concrete policies as separate responsibility groups.
   They may share a horizontal band in a dependency view. Directory nesting and
   Ruby namespace nesting do not determine architectural dependency direction.

## Consequences and limits

Policies and hooks reference the contract definitions in their shared group,
while Agent execution composes and consumes them. The contract files have no
static dependency on Agent execution or MultiAgent implementation classes.
Their dependencies on immutable values, token estimation, canonical JSON,
shared errors, and Storage serialization errors remain unchanged.

The source bodies and mapped file-level dependency graph are preserved. A new
directory group exposes edges previously internal to `agent/`, so aggregate
directory edge counts and strongly connected component sizes can increase.
This is not evidence that the existing file-level cycles were resolved.

The contracts still contain Handoff-related categories and metadata vocabulary.
That semantic coupling belongs to the subsequent Handoff responsibility review.
The mixed root directory and execution cycles also require separate work.

Applications continue to `require "phronomy"` and use the same documented
constants. Individual implementation paths that previously lived directly
under `agent/` have moved; no forwarding files are retained at those paths.

## Verification obligations

Verify ordinary lazy loading and eager loading, canonical constant names,
independently accessing each contract, custom Policy binding, Plan validation,
hook input/result handling, Manifest serialization and restoration, Context
assembly, and existing migration/persistence integration.

Keep the public API snapshot and RBS unchanged. Match each moved file to its
source when comparing dependencies. Record the removal of direct policy/hook
references to the execution directory without presenting aggregate graph
changes as the elimination of all cycles.

The implementation delivery records its test results separately.
