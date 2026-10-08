# R8 unit18: durable cancellation receipt

## Problem

An Orchestrator load can return while recovery of a framework-owned child is still
in flight. If the child needs external factual resolution, Agent captures an
immutable terminal command that will retain the active parent in coordination
wait. A cancelled token supplied to `resume` after command capture previously
cancelled only the live invocation. The earlier command could then persist a
false cancellation snapshot and release the owner. Restart lost the request.

Controlled scheduling reproduced this in both unit16 and unit17, three times out
of three. The original example passed 200 natural repetitions. Without the
applicant's original failure log, equivalence to that initial failure is not
established. The controlled race is independently demonstrated.

## Ownership

Agent owns receipt of cancellation for an exact execution, its existing durable
cancellation ledger, and persistence of the parent execution. MultiAgent still
owns the unresolved-child and pending-parent rules. Execution owns notification
registration and delivery; Engine owns runtime connections. No Agent decision is
moved into those mechanisms or into neutral Persistence/Storage.

`ExactExecution` validates identity, reservation, input and participant binding
before recording a supplied cancellation through `Store#request_cancellation`.
The write runs in its existing off-EventLoop preparation, before recovery or
waiting. If cancellation first becomes visible during EventLoop delivery,
preparation runs again before the live owner is signalled. Recording errors fail
the observer and do not proceed to recovery or notification.

`ExecutionChange#prepare_in` already reads the monotonic cancellation ledger
inside the participant transaction. `ExecutionOutcomeCommitter` now uses that
prepared fact for a pending execution's cancellation metadata. The worker's
captured command remains immutable; it does not query a live invocation or token.

## Ordering and preserved semantics

- Before outcome commit: the transaction sees the accepted ledger entry and saves
  cancellation in both Agent pending metadata and MultiAgent extension state.
- After outcome commit: the ledger retains newly accepted intent without changing
  execution revision or invalidating the in-flight result. The previously saved
  metadata/extension remain a snapshot; the next recovery/change incorporates the
  ledger. Immediate equality between those snapshots and the ledger is not an API
  guarantee. The ledger is the durable source of accepted cancellation intent.
- After owner release: receipt records intent before recovery installation.
- An absent execution is not assigned a cancellation record. A terminal result,
  including one that wins against cancellation receipt, remains unchanged.
- Unknown child external outcomes still require factual resolution. No LLM replay,
  forced child completion or new recovery capability is introduced.

There is no schema change, public API change, new Contract, Registry, subscription
or polling mechanism. This fixes receipt of cancellation observed by the existing
exact-execution path; it does not introduce continuous subscription to an incoming
token after observer registration.

## Verification design

Queue gates hold the outcome worker before commit and after commit/before result
publication. Gates never block EventLoop or hold a storage transaction. Tests
assert ledger persistence, unchanged revision during receipt, pending snapshots,
restart preservation, unknown-child activity and zero LLM replay. Additional
component tests cover validation rejection, write failure, recovery ordering,
late token observation and terminal-result preservation. The pending commit test
also covers committed-response loss.

The original checkpoint fixture now performs phase inspection and snapshot copy
under one backend lock, preventing concurrent after-commit hooks from replacing a
selected checkpoint. Its initial assertion uses the durable ledger because a
request arriving after a saved waiting snapshot need not rewrite that snapshot.
Separate deterministic tests assert the snapshot on each side of the commit.

## Unit18 delivery correction

The first unit18 version checked the incoming token twice inside delivery: once
to decide whether to record, and again to decide whether to signal. Cancellation
between those observations could skip recording but still signal the owner.
A suspended approval execution then exited without a completion reconciliation,
leaving the durable ledger empty.

Delivery now uses one cancellation observation for both decisions. After finding
and validating the current owner, an observed cancellation returns to off-loop
preparation if unrecorded, or signals the owner if already recorded. The separate
preparation and delivery observations remain intentional: scheduling between those
stages can change the token. A notification is never authorized by a different
observation from the one used to enforce its recording prerequisite.

Regression tests use the real suspended owner, registry and EventLoop. They
cancel the incoming token just before delivery or during the owner lookup, and
cover both successful recording and recording failure. They assert recording
before notification, no notification on write failure, off-loop persistence and
unchanged suspended execution contents. No polling or new subscription is added.
