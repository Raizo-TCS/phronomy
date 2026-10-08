# r8 unit16: Explicit cancellation subscription ownership

This responsibility refactor is based on applied unit15, commit
`9aebef9217383cebb7fa3ec8b2d17b5763cd3c5e` (tree
`fcc1bd3bc72ed611a7d4e9090dcf2391b6bc7471`). It addresses B07 only.

## C13 owns registration lifetime

`Concurrency::ResultSubscriptions#explicit_cancellation` registers the existing
CancellationToken notification and owns its disposal through `close`. This is
an internal Execution operation, reusing the existing subscription collection;
it is not a new public registry or a new Tool implementation.

The existing `cancellation` operation delegates its registration bookkeeping to
this method and retains its additional `cancelled?` check. Its `Subscriptions`
subclass retains deadline scheduling. An explicit registration alone neither
checks an elapsed deadline nor schedules a timer.

CancellationToken still owns callback storage, delivery, exception isolation,
and private removal. `on_cancel` still returns the token. Public signatures,
exception types, and the callback behavior are unchanged. In particular, closing
a registration does not retract a callback already taken by concurrent `cancel!`.

## Consumers retain their execution decisions

- C01 TeamCoordinator registers its existing cancellation callback through C13
  and closes the collection in the existing `ensure` block. Team still owns the
  durable cancel request, child cancellation, and terminal outcome interpretation.
- I09 OffloadPool registers its existing operation cancellation callback through
  the same operation. It still owns queue/worker admission, logical settlement,
  deadline promotion, abandonment, and physical completion. Timer registrations
  are closed before cancellation registrations, preserving cleanup order.
- C06 Tool already passes its token to the standard offloaded submitter. Its
  operation dispatch and cooperative/custom-async paths are unchanged. No
  Tool-specific subscription or symmetric copy of Team logic is introduced.

An already-cancelled token may deliver during registration and close the
subscription collection before registration returns. The existing collection's
`add` behavior disposes such a late-added registration immediately. The same
mechanism covers a concurrent `close` during registration.

## Verification and remaining scope

Behavioral checks cover explicit cancellation, expired deadlines without explicit
cancellation, inline and concurrent close, delivery already in flight, callback
failure isolation, and Team/worker cleanup after success and failure. Existing
OffloadPool timeout, cancellation, and physical-completion tests remain applicable.
The AST gate rejects private token-removal calls outside Execution, including
literal reflective calls in Engine and domain code.

B08 configuration access and F01 durable Workflow children are not implemented
here. Public API/RBS, storage schemas, default configuration, and domain rules
are retained. This change does not certify all Contract boundaries or eliminate
the aggregate implementation graph's cycles.
