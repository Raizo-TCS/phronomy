# SharedState moves to MultiAgent

This change applies to the architecture refactoring branch after core commit
`aa9c3d53090bda4deb01b8cab16a43539b6b1deb`. Use the matching core and examples
checkouts; the unchanged gem version number alone does not identify this API.

| Previous Experimental API | API after this change |
|---|---|
| `Phronomy::Agent::SharedState` | `Phronomy::MultiAgent::SharedState` |
| `Phronomy::Agent::SharedState::KnowledgeStore` | `Phronomy::MultiAgent::SharedState::KnowledgeStore` |

The previous name is removed without an alias. Update superclass declarations
and explicit constant references. For example:

```ruby
require "phronomy"

class ResearchTeam < Phronomy::MultiAgent::SharedState
  member Researcher
  max_cycles 3
end
```

Use the public application entry point `require "phronomy"`. The old internal
file `phronomy/agent/shared_state.rb` is removed; arbitrary implementation-file
requires are not a supported partial-loading API.

The DSL, `invoke(input, config: {})` signature, sequential order, shared findings,
termination rules and `{output:, cycles:, terminated_by:}` result remain the same.
`config:` remains accepted but is not forwarded to member invocations. Timeout
is checked between complete cycles and does not cancel an active Agent.

Set `PHRONOMY_PATH` to the matching local core checkout before running
`bundle install` or the examples verification. Example `22_shared_state` now
uses the new superclass, and the examples API preflight rejects mismatched core.

No saved-record or SQL schema migration is required. Do not rewrite the existing
`Phronomy::Agent::SharedState::Instrumented/` generated definition ID: it is
deliberately preserved together with instrumentation version 1. It is not an
alias for the removed Ruby constant. The in-memory KnowledgeStore still lasts
for one invocation only.

See [ADR-053](../decisions/053-shared-state-coordination-ownership.md) for the
ownership and compatibility decision.
