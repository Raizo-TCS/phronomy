# r8 unit16 migration

No application API or persisted-data migration is required.

This core-only update moves explicit-cancellation registration lifetime into the
existing internal `Phronomy::Concurrency::ResultSubscriptions` operation. Team
and OffloadPool use `explicit_cancellation` and `close`, rather than removing
CancellationToken callbacks through reflection.

`CancellationToken#on_cancel` remains public and returns `self`. Its private
callback-removal method remains private. The new internal operation is not an
application configuration option or a public subscription API.

Existing cancellation and deadline behavior is preserved. Deadline expiry alone
does not become a new Team cancellation notification. OffloadPool's existing
deadline promotion and non-interrupting worker completion behavior remain.
An already-dispatched cancellation callback can still run after subscription
cleanup; this refactor does not add a stronger delivery guarantee.

Tool cooperative execution and custom `call_async` implementations are unchanged.
The standard offloaded Tool route benefits from the OffloadPool update without
requiring Tool-specific registration code. Examples sources are unchanged.

Apply from unit15 commit `9aebef9217383cebb7fa3ec8b2d17b5763cd3c5e` in a new
`refactor/r8-unit16` worktree using the package's checked applier. Follow the
existing process shutdown/drain procedure when replacing running code.
