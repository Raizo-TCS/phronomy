# Contributing to phronomy

Thank you for your interest in contributing!

---

## Development Setup

```bash
git clone https://github.com/Raizo-TCS/phronomy.git
cd phronomy
bundle install
```

Run the test suite:

```bash
bundle exec rspec --format documentation
bundle exec rspec --tag integration
```

Run the linter:

```bash
bundle exec standardrb
```

Check that no Japanese characters appear in source files:

```bash
ruby scripts/check_japanese.rb
```

---

## Code Style

- All source files under `lib/` and `spec/` must begin with `# frozen_string_literal: true`.
- All comments, error messages (`raise`), and YARD documentation inside source files must be in **English**.
- Follow [Ruby Standard Style](https://github.com/standardrb/standard) (`standardrb`).

---

## Public API Changes

When adding, removing, renaming, or changing the contract of a public API or
extension SPI:

1. Update `docs/features.md` when the public feature/stability description changes.
2. Add or update YARD `@api public` / `@api private` classification.
3. Regenerate the API compatibility snapshot when the reflected compatibility
   surface changes:
   ```bash
   bundle exec ruby scripts/api_snapshot.rb --write
   ```
4. Update the corresponding hand-written `sig/**/*.rbs` signature when the
   public type shape changes.
5. Validate the RBS environment:
   ```bash
   bundle exec rbs -I sig validate
   ```
6. Add or update a focused spec for the public API or extension contract.

RBS is a typed representation of an API contract that has already been defined
by source behavior, YARD classification, documentation, and focused tests. Do
not make an internal method public, change runtime semantics, or invent a new
extension guarantee merely to make an RBS signature easier to write.

### `@api` classification vs Ruby visibility

Phronomy's YARD `@api` annotation describes the compatibility boundary; it is
not a synonym for Ruby's `public` / `protected` / `private` keywords.

- `@api public` means consumers or extension implementers may rely on the
  documented contract. Ruby visibility still follows the intended calling
  model: ordinary methods may be public, subclass extension helpers may be
  protected, and `initialize` remains Ruby-private while construction is
  exposed through `.new`.
- `@api private` means the method is internal and carries no public compatibility
  promise. It may still be Ruby-public when Phronomy components need to call it
  through an explicit receiver.
- Ruby visibility is therefore not inferred from the `@api` annotation in
  either direction.

Run the annotation coverage guard when changing documented methods:

```bash
ruby scripts/check_api_annotations.rb
```

Ruby-public compatibility for the primary Stable/Beta product surface is
protected by `scripts/api_snapshot.rb` and
`spec/phronomy/api_compatibility_spec.rb`. Extension contracts whose calling
model is protected/private should be protected by focused specs for that
contract rather than by a repository-wide visibility inference rule.

Do not change Ruby visibility merely to make it match an `@api` annotation.

### Async completion boundary

`Phronomy::Task` is the caller-facing completion handle. EventLoop/FSMSession and
OffloadPool are execution/continuation mechanisms, not competing completion
abstractions.

Synchronous work that requires execution away from EventLoop must use an
OffloadPool. Do not create production worker Threads in adapters, backends, or
Tools to emulate asynchronous behavior. Logical waits between Phronomy
lifecycles stay on EventLoop/FSMSession and settle a Task later.

The framework owns Task settlement (`complete`, `fail`, and framework-driven
cancellation). Application code should observe Tasks through `wait_result`,
`on_complete`, `map`, and settlement state. Operation-wide cancellation of
OffloadPool work is supplied through `CancellationToken`.

---

## Architecture Authority and Decision Records

Phronomy has **no universal artifact priority**. Different artifacts answer
different questions. The normative repository rule is
[`017-design-authority-and-adr-governance`](docs/decisions/017-design-authority-and-adr-governance.md);
the complete ADR status/supersession index is
[`docs/decisions/README.md`](docs/decisions/README.md).

Use these authority boundaries:

- Accepted, non-superseded ADRs define architecture intent.
- Source/runtime behavior defines current implementation reality; it does not
  silently amend an ADR.
- Public API and extension-SPI contracts are composite: runtime behavior,
  `@api` classification, formal API documentation, and explicit
  compatibility/contract tests all participate.
- RBS does not create a contract. It types a contract already established by
  those sources.
- Ordinary implementation tests are regression evidence. Only tests explicitly
  maintained as architecture guards or compatibility/contract tests have that
  stronger role.
- Historical, Archived, and Superseded material is non-normative for current
  architecture.

When architecture intent, public contract, and implementation reality disagree,
treat the discrepancy as an **architecture inconsistency**. Do not choose a
winner merely because one artifact is newer. Record the conflict and resolve it
explicitly according to the process in the ADR index.

ADR references should use a file link or the canonical filename key. This is
required for the two legacy `011` decisions because bare `ADR-011` is
ambiguous. Do not renumber historical ADRs to repair that legacy collision.

For Agent Context work, ADR-012 and ADR-013 define the current Journal,
Manifest, Context Policy and persistent Knowledge model. ADR-010 defines the
EventLoop/FSMSession, Task, and OffloadPool execution boundary. ADR-015 defines
the Tool public façade, extension-SPI boundary, and RBS ownership rules.

Legacy `spec/design/*` files must not be assumed to be normative merely because
they remain in the repository. Their final CURRENT/HISTORICAL/ARCHIVED
migration is a separate documentation-lifecycle change.

### Durability, recovery, and failure vocabulary

Architecture-sensitive durability, concurrency, recovery, cancellation, and
external-effect changes must use
[`018-durability-guarantees-and-failure-model`](docs/decisions/018-durability-guarantees-and-failure-model.md).

Do not write a bare claim such as "durable", "recoverable", "safe", or
"exactly once". State:

1. the guarantee subject;
2. the exact guarantee property (for example durable-state restart
   readability, execution resumption, stale durable-transition conflict
   detection, or duplicate external-side-effect prevention);
3. the component/contract that provides it;
4. the applicable F0-F4 failure class(es);
5. whether X0 External Effect Boundary is crossed; and
6. whether the architecture result is YES, CONDITIONAL, or NO, including the
   condition for every CONDITIONAL guarantee.

In particular:

- F0 operation failure and F1 outcome uncertainty are distinct dimensions and
  may co-occur; an F0 result does not prove durable/external outcome certainty.
- durable-transition atomicity is not commit-outcome certainty.
- optimistic conflict detection is not cross-process execution exclusion.
- process/runtime loss (F4) does not imply confirmed durable state was lost.
- X0 external side effects are not automatically atomic with Persistence.
- semantic IDs do not by themselves provide duplicate prevention.
- arbitrary external exactly-once execution is not an unconditional Phronomy
  guarantee.

Fault-injection and recovery tests should state which failure class/boundary
they exercise and must not imply stronger guarantees than the test proves.
F0-F4/X0 are architecture/test vocabulary, not a required public exception
hierarchy.

---

## Mutation Testing

Phronomy uses [mutant](https://github.com/mbj/mutant) to verify that tests detect
real code changes. Mutation tests are not part of the required CI gate. The
repository contains `.github/workflows/nightly-mutation.yml` for mutation-run
automation; whether that workflow is enabled is an operational choice and is
not a normal pull-request requirement.

### Run mutation tests locally

```bash
# All subjects defined in .mutant.yml
bash scripts/run_mutation.sh

# Single subject
bash scripts/run_mutation.sh "Phronomy::WorkflowContext"
```

### Covered subjects

The authoritative subject list is `.mutant.yml`. It currently includes:

- `Phronomy::WorkflowContext`
- `Phronomy::WorkflowRunner`
- `Phronomy::Agent::Context::Capability::Base`
- `Phronomy::LlmContextWindow::TokenBudget`
- `Phronomy::Agent::ContextAssembler`
- `Phronomy::Agent::ContextPolicies::Default`
- `Phronomy::Agent::ContextPolicyInputBuilder`
- `Phronomy::Agent::ContextPlanValidator`
- `Phronomy::MultiAgent::HandoffPolicy`
- `Phronomy::MultiAgent::HandoffProjection`
- `Phronomy::VectorStore::InMemory`

The nightly mutation matrix mirrors this authoritative list so each subject can
run in an isolated job with its own timeout. The regular test suite includes a
configuration-consistency guard that fails if the nightly subject set diverges
from `.mutant.yml`.

The Tool mutation subject intentionally uses
`Phronomy::Agent::Context::Capability::Base`, which is the implementation
canonical name returned by the single Class object's runtime `Class#name`.
`Phronomy::Tool::Base` is the public facade constant alias to that same Class
object; it is not a second Tool base class.

When you add or modify tests for a covered subject, run mutation tests locally
when practical and investigate meaningful score regressions.

---

## Releasing

See [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for the full pre-release quality
gate and step-by-step release instructions.

**Never run `gem push` directly.** Releases are published via the GitHub Actions
`release.yml` workflow.
