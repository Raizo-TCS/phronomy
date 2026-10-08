# r8 unit17 migration

This core-only update requires no application or stored-data migration.
Continue using Phronomy.configure and the existing per-instance/per-invocation
options. Public names, defaults, policy validation, nil semantics, and explicit
option priority remain unchanged.

Agent and Workflow read their own option values instead of application
Configuration. MultiAgent uses its optional configured Store provider. Logging
uses RuntimeSettings. Authorization pool sizing moves into the execution
connection while Agent retains approval and timeout decisions.

There is no settings-change notification or automatic in-flight update. Existing
read timing is preserved, including scoped configuration restoration and reset.
Do not capture an internal settings object as a permanent replacement for the
current accessor, or depend on Configuration's private instance variables.

Private Agent ExecutionEnvironment implementations used by internal integrations
or tests must implement submit_authorization(timeout:, cancellation_token:, &block).
The default Engine connection submits the same authorization work with the same
pool name, resource defaults, overload behavior, and owning Runtime. Ordinary
Tool implementations and application code require no changes. Tests should set
configuration through its writers rather than intercepting an old facade getter.

Apply from unit16 commit `fb551e1a1a8334b2547ecad126dd9c152c1b0f8c` in a new
`refactor/r8-unit17` worktree using the package's checked applier. Follow the
existing shutdown/drain procedure when replacing running code. Examples remain
on their unit6 sources and are verified against this core through PHRONOMY_PATH.
