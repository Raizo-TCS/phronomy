# R8 unit19: Engine resource lifetime

## Confirmed failures

Overlapping first default-pool lookups could construct two pools and retain only
one. A pool lookup that passed Runtime's state check could also create a pool
after shutdown had captured its resource list. Both cases left live workers
outside the claimed completed cleanup.

OffloadPool previously returned after each worker join timeout without reporting
whether workers remained. Runtime interpreted the absence of an exception as
successful cleanup. A real blocked worker was still active after the default
30-second join while Runtime reported terminated, clean and complete.

## Ownership

PoolRegistry owns pool creation, registration and closure of that registration.
The same mutex protects default and named pool construction and the transition
to a closed registry. Runtime still admits resources during its draining phase
for previously accepted continuations. PoolRegistry rejects requests after the
shutdown resource set is captured, including lookups that passed an earlier
Runtime check.

OffloadPool owns worker admission and physical worker lifetime. begin_shutdown
closes admission without waiting and preserves queue draining. shutdown waits
using one monotonic deadline; its existing self return is preserved. terminated?
reports that admission is closed and every owned worker has actually exited.
TaskResult cancellation or timeout is not proof of physical worker termination.

PoolRegistry first closes all pools, then waits outside its registration lock.
Every pool uses the same absolute deadline. Cleanup continues for the remaining
pools after an individual error; the first error is propagated after those
attempts. Runtime still attempts timer cleanup in ensure.

Runtime owns the aggregate decision. Its existing stop-phase deadline is shared
by EventLoop and pool joins. Cleanup is incomplete while any worker remains;
domain finalization and default-Runtime replacement remain blocked. Runtime's
existing cached-result behavior is unchanged: an incomplete result is not later
promoted to complete by calling shutdown again.

## Scope

This is an Engine lifecycle correctness fix, not only a file relocation. Pool
shutdown no longer silently reports completed resource cleanup when workers
remain. The pool waiting budget is shared instead of being restarted per worker
or per pool. No worker is forcibly interrupted, and queued accepted work still
drains. Applications retain responsibility for bounded synchronous operations
and native I/O timeouts.

Agent cancellation persistence, MultiAgent parent/child policy, Workflow
persistence decisions, C13 result/subscription contracts, settings providers and
durable formats are unchanged. No new domain Contract or notification mechanism
is introduced. E03 passive metrics collection remains a separate follow-up.

## Verification

Queue-controlled tests reproduce overlapping first pool creation and lookups
delayed until after shutdown. Real worker gates verify bounded shutdown,
incomplete results, retained Runtime, withheld finalization and the difference
between logical cancellation and physical completion. Additional cases preserve
draining continuations and ensure all resources receive cleanup attempts.
