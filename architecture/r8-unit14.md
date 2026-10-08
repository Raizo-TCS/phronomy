# r8 unit 14: assign existing recovery rules to their owners

The former private `Phronomy::Recovery` combined Agent operation subjects and
factual resolutions with general persistence evidence comparison. Sharing a
file or using the word recovery does not make these one Contract.

| Responsibility | Owner after this change |
| --- | --- |
| LLM/Tool subject identity, resolution material, resumability classification | C04 Agent, private `Agent::RecoveryRules` |
| Revision/snapshot evidence comparison and normalization | C07 Persistence, private `Persistence::SnapshotComparison` |
| Selection of Workflow evidence and interpretation of pre/post/conflict | C02 Workflow, existing WorkflowRunner |
| Agent restoration, resolution save/readback and continuation | C04 Agent, existing RecoveryCoordinator |
| Parent/child coordination and durable reconciliation | C01 MultiAgent, unchanged |

There is no independent Recovery Contract. C14 remains retired; C17 is
OutputParser. M50/G34 are retired in the current source architecture without
reusing their identifiers. Historical phase configurations retain their history.

## Behavioral scope

This is a relocation of existing rules and their call sites. No public API,
persisted schema, outcome value, retry, observer, admission or ownership rule is
added. Error classes/messages and validation ordering are retained. Ordinary
framework boot still loads the relocated definitions. The former private
namespace and file are removed, without a compatibility alias. The existing
public `Phronomy::ExecutionRehydrationRequiredError` moves to `agent/api` while
retaining its root namespace, superclass and lazy-loading behavior; it remains
an Agent-domain outcome, also consumed by delegation callers.

`Agent::RecoveryRules` describes external operation facts as `succeeded`,
`failed` or `not_performed`. Its `Classification` describes resumability. The
existing structural `persistence_operation` subject normalization is retained
to avoid changing accepted input or errors; it does not provide a new generic
durable operation identity or a new supported Agent resolution operation.

`Persistence::SnapshotComparison` returns `pre_state`, `post_state` or
`conflict`. It performs no I/O. Workflow supplies authoritative readback and
intended evidence, handles read errors, and decides completion, known failure
or recovery-waiting admission retention. In particular:

- An absent record with an absent expected pre revision remains pre-state.
- Without an explicit post revision, a matching normalized snapshot and a
  revision different from the expected pre revision identifies post-state.
- With an explicit post revision, both revision and snapshot must match.
- Otherwise a matching pre revision identifies pre-state, even if the snapshot
  differs. The explicit post comparison still precedes this check.
- Accessors precede symbol keys, which precede string keys. Nested hash keys
  and symbol values normalize to strings. Read/accessor errors propagate to
  the owning domain as before.

`Persistence::SaveOutcome` is unchanged. It compares domain-supplied before/after
evidence using its existing equality and reports `committed`, `not_committed`
or `unknown`. It is not substituted for snapshot comparison: their predicates
and error handling differ. Agent-specific execution metadata comparisons also
remain in Agent.

## Verification and limits

The relocated specs retain existing cases. Additional regressions fix comparison
priority, normalization, accessor precedence, error identity, resolution error
ordering and subject immutability. The same 45 primitive examples pass against
the unit13 definitions and the relocated definitions. Existing Agent recovery
and Workflow terminal persistence tests cover their surrounding behavior.

AST and combined Ruby/RBS graph gates reject dependencies from other domains on
Agent recovery rules and domain references in generic persistence comparison.
These checks guard this boundary, not all possible semantic coupling. Root
loader wiring and dynamic injection require separate review and runtime tests.

Durable Workflow children (F01) remain deferred feature work, outside this
responsibility refactor and outside its acceptance criteria. This change does
not establish global acyclicity or completion of every Contract.
