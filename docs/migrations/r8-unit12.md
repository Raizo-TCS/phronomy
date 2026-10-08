# Migrating to r8 unit 12

Apply after core 891ddf62da42e5218fd8f80d5a9ec0ac6b58b81d (unit 11).
This package changes core only. The unit 6 examples at
ed455c52018338f7c5a4c2948ae0d7db131aa090 require no source changes.

Continue to use Orchestrator.subagent and Tools::Agent.from_agent as before.
No application API or database migration is required. Orchestrator still
inherits Agent::Base. Its generated Tool is now a direct Tool::Base subclass.

| Internal assumption | Current structure |
| --- | --- |
| A generated subagent Tool is a Tools::Agent subclass | It implements Tool::Base directly and belongs to MultiAgent |
| Tools::Agent owns generic asynchronous Tool validation and error handling | Tool::Base supplies private asynchronous operation rules |
| Generic Tool handling knows Agent recovery errors | Agent-aware callers preserve those outcomes |

Code that inspects generated-class ancestry or changes Tools::Agent globally
to affect Orchestrator-generated Tools relied on the old implementation link.
Such changes no longer apply to generated subagent operations. Existing Tool
DSL options on the generated operation retain their semantics. The new private
helper is not a public asynchronous implementation API.

The ZIP includes complete changed files, strict-base application and
expected-tree verification, a review patch, verification evidence and application
instructions. Use a new worktree and run --check, --apply and --verify; run
--verify again after committing. Follow the existing stop/drain procedure when
replacing running processes. No new cross-version in-flight guarantee is made.

For examples verification, unset BUNDLE_GEMFILE and set PHRONOMY_PATH to this
core. Inspect and restore generated lockfile/vendor changes; no examples commit
is needed. Live PostgreSQL and provider verification remain environment-specific.
