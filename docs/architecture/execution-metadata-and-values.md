# Shared execution metadata and value conversion

Refactor 38 addresses the remaining R03 and R11 responsibilities against core
`e7e6618493df03c2eb386d78a9303796e1e13cdc`. The candidate must be applied and
verified before those items are closed. Tool restoration itself was completed
earlier and its validation and state reconstruction remain unchanged.

## Ownership

Ordinary dispatch creates durable facts before sending an external operation.
Recovery reads those same facts after an interruption. Their stored vocabulary
therefore belongs to the execution contract, not to a recovery procedure.

| Responsibility | Owner | Callers |
|---|---|---|
| Metadata keys/version, Tool batch capture and metadata merge | `Agent::ExecutionMetadata` in `agent/execution` | Initial/dispatch preparation, Coordinator, approval commit, recovery and MultiAgent |
| Stable Tool invocation identity | `Agent::ToolInvocation.semantic_id` | Ordinary Tool preparation and recovery subject construction |
| Ruby tree conversion before JSON serialization | `Values::Serializable.convert` in `common/values` | RuntimeRecordEncoder, RecoverySupport, ExecutionMetadata and dispatch preparation |
| Recovery descriptors and outcome interpretation | `Agent::RecoverySupport` | Recovery and the existing failure reconstruction path |

ExecutionMetadata is a stateless vocabulary and snapshot helper. It does not
start an invocation, increment revisions, open a transaction or perform recovery.
Its `with_values` preserves the old execution revision. ToolInvocation's
`semantic_id` computes the same prefixed SHA-256 value over the same four IDs
and NUL separators; it never constructs, authorizes or runs a Tool.

RecoverySupport's shared constants and snapshot/merge/identity operations are
removed, with all repository callers updated. No compatibility aliases are
added for these private implementation names. `ExecutionOutcomeCommitter`
still uses `RecoverySupport.error_from_failure` for actual failure reconstruction;
this change does not claim to remove every execution/recovery dependency.

## Conversion contract

Serializable rebuilds Hash and Array containers, stringifies Hash keys and
Symbol values, retains scalar objects, and recursively processes `to_h` results.
It preserves input order and the previous last-value-wins behavior for keys
that become equal. It does not deep-copy String values, freeze results, reject
non-Hash `to_h` results, or catch exceptions raised by application conversion.

The unsupported-value error remains ArgumentError. Callers supply their
existing diagnostic prefix, including for errors inside nested values:

| Boundary | Exact prefix before `: <class>` |
|---|---|
| RuntimeRecordEncoder.json_value | `unsupported canonical runtime value` |
| RecoverySupport.canonical_copy and existing snapshot writers | `Recovery value is not canonically serializable` |

The two existing conversion entry points remain short adapters because they
own different error contracts. They no longer implement separate recursive
algorithms. Snapshot writers retain their historical diagnostic despite its
Recovery wording, to avoid a behavior change in this responsibility refactoring.

Serializable does not establish canonical JSON validity. CanonicalJSON still
owns numeric range, non-finite/negative-zero and encoding checks. Immutable.copy
still owns copying and freezing. ProviderCallOutcome.normalize still has its
different unsupported-value-to-String behavior. Domain codecs keep their key
validation and collision rules. These operations are intentionally not merged.

## Compatibility and verification

Stored metadata keys, version 1, Tool identity bytes and serialized values are
unchanged. Transactions, revision checks, dispatch order, Tool restoration,
approval notifications and external-effect behavior remain with their existing
owners. Public API, signatures, raw Storage SPI and database schema are unchanged.

The conversion behavior tests run against both the applied baseline and the
candidate, including nested unsupported values and application exceptions.
Existing Tool batch tests follow their new owner; the stored identity fixture
guards compatibility. Recovery, causal durability, approval/resume and
MultiAgent tests exercise the changed callers. Full core/integration suites,
common examples, real SQLite, API/SPI snapshots, RBS, annotations and packaged
gem loading complete the candidate checks. Live PostgreSQL and live providers
are not part of this candidate's execution evidence.

This improves ownership and removes a duplicated recursive algorithm. The
dependency diagram's module and file cycles remain; their disappearance is not
the completion criterion. The applied SVG remains applied37-01 until the next
application verification. The other initial proposal groups are R06, R07,
R08/D08, R09 and R10; overall refactoring is not complete.
