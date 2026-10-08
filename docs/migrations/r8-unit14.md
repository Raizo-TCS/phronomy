# r8 unit 14 migration

Apply to unit13 core commit `cf659de00b9adc2641e1c68014d756e761ccc8e1` using
the package applier in a clean checkout. Only core changes; examples source
remains at unit6 commit `ed455c52018338f7c5a4c2948ae0d7db131aa090`.

Public Agent resolution and Workflow APIs are unchanged. There is no data
migration, persistence format change or new application configuration.

Private consumers must replace the removed `Phronomy::Recovery` namespace:

| Former member | New private owner |
| --- | --- |
| Classification, dispositions, resolution outcomes, missing-material sentinel | `Phronomy::Agent::RecoveryRules` |
| Subject normalization/identity and resolution material validation | `Phronomy::Agent::RecoveryRules` |
| Revision and snapshot comparison, value normalization and record access | `Phronomy::Persistence::SnapshotComparison` |

The existing public `Phronomy::ExecutionRehydrationRequiredError` keeps its name
and superclass; its file moves to `agent/api/execution_rehydration_required_error.rb`.

The old internal file `lib/phronomy/recovery/recovery.rb` is removed.
Ordinary `require "phronomy"` loads both replacements. Direct loading of
internal files remains unsupported; do not treat these private modules as new
application extension APIs. Existing `Persistence::SaveOutcome` is unchanged.

Use the same process stop/drain and deployment procedure as unit13. This unit
adds no in-flight version interoperability or external side-effect rollback
guarantee. Retain the unit13 checkout for rollback; revert the applied commit
if necessary. Package README contains apply, validation and commit instructions.

Workflow durable children (F01) are deferred and are not included in this unit.
