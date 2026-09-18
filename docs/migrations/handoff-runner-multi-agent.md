# HandoffRunner moves to MultiAgent

This change applies to H1 on `refactor/architecture` after core commit
`fe2ad7cea6945a240858b18645dc4ae285e8ce64`. The released 0.26.0 gem does not
yet provide this new Runner name.

| Previous API | API on this refactoring branch |
|---|---|
| `Phronomy::Agent::HandoffRunner` | `Phronomy::MultiAgent::HandoffRunner` |
| `Phronomy::Agent::Handoff` | Unchanged |
| `Phronomy::Agent::HandoffPolicy` | Unchanged |

The previous Runner name is removed without an alias. Update direct `require`
paths from `phronomy/agent/handoff_runner` to `phronomy/multi_agent/handoff_runner`
if used; ordinary `require "phronomy"` continues to use Zeitwerk.

Runner initialization still accepts `main_agent:` and `handoffs:`. Its `invoke`,
`cancel` and `result` methods, `main_agent`/`handoffs` readers and `MAX_HANDOFFS`
constant retain their behavior. Existing Handoff edges and Policy objects remain
in the Agent namespace during this first step.

Update the core and examples together. When using examples from the corresponding
refactoring branch, set `PHRONOMY_PATH` to the matching local core checkout before
resolving bundles or running verification. The examples API preflight rejects an
older core and checks exact removed constants without mistaking
`MultiAgent::HandoffRunner` for `MultiAgent::Handoff`.

No persisted-record migration or SQL schema change is required. Existing
HandoffState, Context and execution records are read using the same format,
identity and revision rules. Recovery still requires compatible current Agent
definitions and Handoff graph wiring; changing the Runner namespace does not
relax that requirement.

The ownership rationale and remaining work are recorded in
[ADR-034](../decisions/034-handoff-runner-coordination-ownership.md).
