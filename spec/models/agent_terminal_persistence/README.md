# Agent terminal persistence model

This bounded TLA+ model checks the private G3b-1 persistence primitive: retain a
complete detached proposal, classify authoritative evidence, and retry only its
exact persistence writes. It does not model completion of the original Agent
owner, admission, Runtime custody or original observer. Those G3b-2 operations
remain outside this slice.

For example, an original transaction can roll back all newly staged content
while its detached evidence still retains the bytes. A later guarded retry can
restore the same content reference and terminal journal identities without
calling a provider, tool, parser or terminal encoder again.

## Source correspondence

The model begins after the complete proposal and its content writes have been
captured. Symbolic record values stand for complete values and identities, not
only status or revision numbers. No replayable execution closure is retained.

For example, an unchanged execution with a changed root, journal suffix or
cancellation ledger is different evidence. An execution-only comparison cannot
authorize retry or confirm the captured post-state.

| Model | Ruby correspondence |
| --- | --- |
| `capturedBefore`, `capturedAfter` | `TerminalPersistenceEvidence#before` / `#after`, detached from `ExecutionChange#captured_evidence`. |
| Root, execution, journal and cancellation fields | Complete standalone Agent evidence read by `ExecutionChange.read_agent_evidence`; participant evidence is excluded. The journal symbol includes captured suffix identities/sequences and consistency with the actual journal head. |
| `Content`, `capturedContent` | `ContentWrite(reference, bytes, canonicalization_version)` captured through `RecordingContents`. |
| `Reconcile`, `Classify` | `TerminalPersistenceEvidence#reconcile` / `#classify`: complete comparison and, for post-state, exact referenced content bytes. |
| `BeginRetry`, `lockHeld` | `#retry` acquires the Agent guard, classifies current complete evidence and stages writes inside the same outer transaction. |
| `CommitRetry` | `#replay` writes the captured bytes/version, verifies references, appends the exact journal records, and saves captured execution/root with the original guards/CAS. |
| `RollbackRetry` | Transaction rollback removes staged writes while preserving durable preexisting content. Detached capture survives. |
| `LoseRetryReply`, `Reconcile` | Lost retry response followed by comparison of the same proof, through rescue readback or a later caller if readback was unavailable. |

The captured version is supplied again on retry. Post-read content equality uses
reference and bytes; the ContentStore fetch interface does not independently
expose persisted version metadata. The model does not claim to verify it.
Concrete tests must also validate the original Store's opaque binding token,
immutable Ruby values, result diagnostics and content-address computation.
The evidence identity is stable across retries; it is not a Runtime attempt ID.

## Checked properties and deliberate controls

Safety separates a read result from permission to overwrite. The retry performs
its own full comparison under the transaction guard, even after an earlier
read reported noncommit. Post-state produces no writes; changed or unreadable
evidence produces unknown and does not authorize retry.

For example, cancellation accepted after capture must remain visible. Holding
the same guard across comparison and writes excludes an intervening update;
the split check/write mutation deliberately permits it and is rejected.

- Observation soundness requires complete matching evidence and post content;
  a noncommit observation additionally requires original backend settlement.
- Retry writes require exact guarded pre-state and reproduce the captured
  terminal rows, journal identities and content bytes/reference/version.
- Successful terminal commit is not duplicated; rollback neither leaks new
  content nor deletes preexisting shared content.
- Comparison is read-only, proposal computation occurs once, and modeled
  provider/tool/parser invocation counts do not increase.
- Only the outer transaction can publish success. Nested scope refusal is
  represented without inferring success from a savepoint.

The 20-case manifest contains six positive property configurations, nine
deliberate mutation controls and five reachability witnesses. Mutations cover
missing content capture, split check/write, execution-only comparison, omitted
cancellation/content checks, business replay, broken content rollback and
confusing local return with backend settlement. A mutation must violate its
named invariant. A witness intentionally violates the negation of the desired
reachable state. These expected counterexamples are sensitivity checks, not
unfixed failures in the accepted model.

## Backend and progress premises

Original transaction settlement and authoritative read ordering are backend
premises. A local worker or TaskResult returning does not establish either one.
The model keeps `settled` separate from read availability and does not permit a
valid noncommit classification before settlement.

For example, if a remote transaction can commit after a pre-state read, the
read does not prove noncommit. `bug-local-return-is-settlement` deliberately
allows that unsupported inference and violates observation soundness. The
production private API documents this caller/backend precondition; it does not
implement a new Runtime settlement-capability gate.

The three progress profiles supply their calls explicitly. Post-read progress
starts with exact post-state and readable storage. Pre-retry progress starts
settled, readable and unchanged, assumes the retry transaction commits and its
response returns. Lost-response progress additionally supplies a fresh compare
after the loss. Fairness on these call actions is an explicit caller/reactivation
premise, not an automatic retry service. Interference, rollback and pending
original settlement profiles promise safety only. Finite call budgets can be
consumed by unavailable results; fairness does not create a third request.

## Bounds and limits

The model has one captured proposal, one original backend transaction, one
active guarded retry, at most two retry calls and two comparison calls, one
external evidence change and one loss/recovery of read availability. Guarded
transactions are serialized. This is a finite protocol abstraction, not a Ruby
refinement proof, an unbounded concurrency proof or a backend conformance test.

For example, the single content item stands for the captured set of writes.
Content already present before retry must survive rollback; staging a new item
does not make it durable. Actual collections, byte copying, SHA references and
repository atomicity require implementation tests. `txContent` retained after
rollback is historical detached attempt material, not durable staged content;
only `blob` represents that item's backend visibility.

The model starts only after complete capture; earlier exceptions are excluded.
Standalone installed completed/failed/cancelled terminal proposals are covered
as symbolic outcomes. Participants, reservations/extensions, suspension,
handoff, approval, dispatch and preparation are excluded. The optional
`commit_outcome(command, on_evidence: ...)` callback must be retained by its
caller; default coordinator behavior is not repaired by this private primitive.
There are deliberately no owner-release or observer-repair state transitions.

## Running the checks

The runner uses an externally supplied TLA+ tools jar and writes all logs,
traces and counts outside the model source directory. It checks the expected
result class and named invariant, rather than treating any failure as success.

For example, from the repository root:

```sh
python3 spec/models/agent_terminal_persistence/run_checks.py \
  --jar /path/to/tla2tools.jar \
  --output /tmp/agent-terminal-model
```

Development uses OpenJDK 21.0.13 and TLA+ tools 1.7.4 / TLC 2.19. The jar SHA-256
is `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.
`summary.json` records the actual source/config hashes, Java version, commands,
return codes, state counts and expected-result agreement. Generated evidence
and the jar are not repository source files.
