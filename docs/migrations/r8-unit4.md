# r8 unit 4 migration

Update core and examples together. This is a refactoring-branch breaking change;
there are no compatibility aliases or automatic old-record loaders.

| Unit 3 | Unit 4 |
|---|---|
| `Agent::Handoff`, `Agent::HandoffPolicy` | `MultiAgent::Handoff`, `MultiAgent::HandoffPolicy` |
| `stores.team`, `config.team_store` | `stores.multi_agent`, `config.multi_agent_store` |
| HandoffRunner infers an Agent store | `HandoffRunner.new(main_agent:, handoffs:, persistence: stores.multi_agent)` |
| Orchestrator receives only Agent persistence | `Orchestrator.create(persistence: stores.agent, coordination_store: stores.multi_agent)`; pass both on `load` |
| Internal ExactExecution/metadata access by coordination | Agent reserved start, resume, cancellation and observation operations |
| AgentExecution / HandoffState envelope `0.1` | Envelope `0.2`; explicit offline conversion required |
| `coordination`, `multi_agent_coordination_ref`, Handoff result fields | immutable `reservation`, versioned `execution_extension`, `transfer_receipt` |

Construct one `PersistenceComposition.build(backend:)` and use its domain stores.
Ordinary Agents continue to use `persistence: stores.agent`. For custom
participants, follow `ExecutionChange`'s RBS contract and the
[transaction sequence](../architecture/r8-unit4.md). Do not serialize participant
objects, callbacks or live Agent references.

## Offline SQL conversion

Stop all writers before exporting, including background workers and other
processes. Keep the old database unchanged. Run commands from example 30 (SQLite)
or 31 (PostgreSQL), with `PHRONOMY_PATH` pointing to the unit 4 core. The source DB
must have the unit 3 schema. The destination must be a separate empty database.

```sh
export SOURCE_DATABASE_URL='sqlite3:/absolute/path/old.sqlite3'
export DESTINATION_DATABASE_URL='sqlite3:/absolute/path/new.sqlite3'
bundle exec ruby ../scripts/migrate_unit4.rb export source.json --quiescent
bundle exec ruby ../scripts/migrate_unit4.rb convert source.json converted.json --quiescent
bundle exec ruby ../scripts/migrate_unit4.rb import converted.json --quiescent
bundle exec ruby ../scripts/migrate_unit4.rb verify converted.json --quiescent
```

Use the corresponding PostgreSQL URLs with example 31. The importer creates the
new destination schema, including retention/cancellation tables, refuses populated
tables, and commits all resources together. It preserves record IDs, physical and
logical revisions, stream positions, result/error content, transfer provenance,
knowledge order and unresolved work. A content digest, reference, owner, revision
or format mismatch aborts conversion. A checksum binds the converted resource set
to its validation. Do not edit converted JSON manually.

Verification establishes a separate connection pool and compares the complete
exported destination with the converted snapshot. Before switching application
configuration, load representative Agents with their current definitions and
participant wiring, read completed results and resume only continuations whose
external outcomes are known. Unknown external operations remain unresolved; the
migration neither retries them nor declares them complete. Keep both exports and
the old DB until that operational validation is complete. Database cutover is
explicit and is never performed by the migration command.

For non-SQL backends, `Unit4Migration.convert(snapshot, quiescent: true)` is the
pure conversion boundary. Implement offline export/import of the documented
`phronomy.snapshot/1` resources using the backend's own driver. No live-code
fallback is supplied.

## Retention lifecycle

After all results in a conversation have been consumed, call
`runner.forget_history!` (or `stores.multi_agent.forget_handoff(main_id)`) before
purging retained participants. For completed durable subagent history use
`stores.multi_agent.forget_subagents(agent_id:, execution_id:)`. Active or
unresolved work rejects history deletion. These operations release their own
holds; they do not remove another conversation's references.
