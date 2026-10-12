# Agent scope and incarnation lifetime (DX05-E core)

An application decides how long it needs an Agent. C04 owns the mechanics for
acquiring that incarnation and releasing it safely. A scope does not delete saved
Agents, stop other Agents, close an application-owned Store, or infer whether a
business operation should be retried.

## Application change

Before, a long-running application could create Agents for each request, but
the Runtime retained their mutable incarnations until shutdown. `close!` changes
the durable Agent lifecycle; `purge!` deletes saved state. Neither is a substitute
for releasing a process-local incarnation.

```ruby
agent = ReviewAgent.create(persistence: store)
agent.invoke(text) # the Runtime still owns this incarnation afterwards
```

After, the application declares the ownership boundary once:

```ruby
Phronomy::Agent.open_scope do |agents|
  agent = agents.create(ReviewAgent, persistence: store)
  agent.invoke_async(text)
end
```

`open_scope` waits for a returned TaskResult and returns its resolved value (or
raises the original exception). A plain block value is returned unchanged.
It then attempts to unload every Agent it acquired. A Workflow can use
`agents.create_async` or `agents.load_async` from EventLoop and compose their
TaskResults. The outer application keeps the scope alive until the Workflow has
finished. A scope is not serializable Workflow context.

An existing application-owned Agent cannot be adopted by `scope.load`: that
would give the scope permission to release someone else's object. The attempt
raises `AgentBusyError`. Repeated load in the same scope returns its live instance,
after checking class and Store compatibility. A listener cannot be replaced on
an already live instance. Existing `Agent.load`/`get` lookup semantics remain;
obtaining a reference does not extend its owning scope's lifetime.

## Release contract

`agent.unload_async` returns `TaskResult<Boolean>` and is EventLoop-safe.
`agent.unload!(timeout: nil)` waits externally. Both preserve all durable state:
root and context revisions, journal position, contents, history, metadata and
lifecycle status. A closed Agent remains closed after reload.

Release requires an exact live owner, no accepted operations or execution
admission (including approval and recovery waits), and an idle durable execution
ledger with no retention references. C04 interprets only the presence of opaque
retention references; their owning domain decides when to remove them.

Concurrent release requests share the pending handle. A successful release
returns `true`; an already unloaded reference returns `false`. A wait timeout
does not cancel the release. Store check failure rolls back the reservation and
preserves the original error. Runtime shutdown closes admission and drains
already accepted transition completion without creating a replacement Runtime.

New operations cannot enter during release. Old Agent operations fail with
`AgentUnloadedError` (`code: "agent.unloaded"`, `agent_id`); asynchronous methods
return failed TaskResults. Immutable snapshots and `agent_id` remain usable.
A later load creates a new instance and can bind a new listener. The old
reference cannot mutate or release that new owner. Purged Agents keep their
existing `AgentPurgedError` semantics.

A concurrent `get` or `load` during release raises `AgentBusyError` immediately;
it does not wait or create a second owner. Accepted operations make unload fail
with Busy at its admission gate. In particular, unload inside an Agent terminal
listener is Busy while that listener is executing. Exit the outer application
scope after result delivery to release it. Existing immutable local-state reads
remain available while Runtime shutdown is draining an incomplete transition;
new execution and mutation admission stays closed.

## Failure and cancellation

Scope tracks materialization receipts before starting work and registers acquired
Agents before returning them. Closure stops new acquisition and waits for the
physical completion of accepted materialization, even when its handle was
cancelled. Indeterminate durable create keeps the C04 recovery reservation and
logs the Agent ID; it is never silently made creatable again.

Scope does not cancel or wait for unjoined child execution as an implicit
cleanup policy. An active Agent is retained and cleanup reports `AgentBusyError`.
If the main operation failed, its same exception is preserved and secondary
cleanup failures are logged with Agent IDs. Logger failure cannot replace it.
If the main operation succeeded, failed cleanup raises `Agent::ScopeCleanupError`
(`code: "agent.scope_cleanup_failed"`). `result` preserves the successful value;
`failures` is an array of `{agent_id:, error:}` with the original exceptions.
All acquired Agents are attempted. No automatic retry, purge, or retention
removal is performed.

## Responsibility and ordering

- C04 owns scope receipts, exact incarnation identity, operation admission,
  busy/retention rules, invalidation and cleanup errors.
- C07 supplies the existing transaction boundary. C04's Agent Store supplies
  `assert_idle!`, `guard_agent!` and retention reads; neither Persistence nor
  physical Storage gains incarnation release policy.
- C13 supplies existing TaskResult and physical-completion contracts. It gains
  no scope membership, Agent busy rules or unload states.
- Engine supplies existing worker execution, serial EventLoop delivery and
  shutdown participation. It gains no Agent-specific states.
- The operation lease and release reservation share the C04 ownership mutex.
  No Store transaction, Runtime call, application callback or blocking wait runs
  under that mutex. Accepted runner continuations use C04 internal snapshots;
  callbacks initiating a new public operation must acquire a new lease.
- Agent operation completion is distinct from cancelling its public handle.
  C04 acknowledges release after domain terminal/listener delivery and physical
  worker completion. A queued or physically running cancelled operation still
  blocks release.

For notifications, finish child processing, drain notifications, then exit the
Agent scope. `run_once` retains its existing Store and lifetime behavior; merely
calling it does not opt into scope cleanup.

This is P5 (core). P6 migrates application examples and performs cross-repository
acceptance against the published or pinned candidate core.
