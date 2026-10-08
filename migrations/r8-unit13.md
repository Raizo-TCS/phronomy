# Migrating to r8 unit 13

Apply after core 87685e3544901a3b2b2d6e9841a723f8ce05c6f6 (unit 12).
This package changes core only. Unit 6 examples at
ed455c52018338f7c5a4c2948ae0d7db131aa090 require no source changes.

Workflow.define, invoke, invoke_async, signal, stream and resume retain their
call signatures and persistence format. No database migration is required.
Compiled Workflows now retain the execution environment selected at compilation.
When replacing/resetting the Runtime in a process, drain/stop existing work and
compile new Workflow objects for the new Runtime. A Workflow whose owner has
stopped rejects work; it does not implicitly adopt the replacement Runtime.

| Internal assumption | Current structure |
| --- | --- |
| Runner looks up the global Runtime during each execution step | It retains a private WorkflowExecutionEnvironment |
| Workflow registry constructs an Engine Event | It supplies an atomic target resolver to the C13 receiver channel |
| Phase compiler owns callback rules | WorkflowActionRules owns the rules; the binding installs callbacks |
| Workflow terminal policy belongs to domain execution files | It translates domain outcomes in workflow/runtime_binding |

WorkflowPhaseMachineBuilder and WorkflowTerminalPolicy retain their constant
names but move from workflow/execution to workflow/runtime_binding. They remain
private; direct internal require paths or private Runner helpers must be updated.
No application implementation of the environment port is required or supported
as a new public API. Admission, repository operations and result classification
remain Workflow-owned.

The ZIP contains complete changed files, strict base checks, deletion handling,
expected-tree verification, a review patch and validation evidence. Apply in a
new worktree; run --check, --apply and --verify, then --verify after committing.
For examples, unset BUNDLE_GEMFILE and set PHRONOMY_PATH to the new core. Inspect
and restore generated lockfile/vendor changes. No examples commit is needed.

This change does not introduce durable child execution, cross-version in-flight
compatibility or external-side-effect rollback. Keep the existing stop/drain and
recovery procedures when replacing running processes.
