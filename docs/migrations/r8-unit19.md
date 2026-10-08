# R8 unit19 migration

Apply to core at unit18 delivery-correction commit
`a6f370d34e90ca274ec45a6b69ad1db9cb003707`.
No examples source change, data migration or public invocation API change is
required. Engine-private shutdown operations and their RBS declarations change.

Runtime shutdown now reports incomplete cleanup when workers remain alive. Check
cleanup_complete? before declaring resources released. reset_runtime! continues
to reject replacement after incomplete cleanup. Do not bypass that guard or
assume a cancelled TaskResult means its synchronous worker has stopped.

The existing Runtime stop-phase deadline, computed from cancel_grace with its
existing minimum grace, now also bounds pool joins. It is shared across EventLoop
and all pools; the previous additional 30 seconds per worker no longer applies
to Runtime shutdown. timeout still controls the preceding drain phase. Choose
grace appropriate to existing work, and configure native I/O timeouts where
needed. No Thread#raise or hard worker termination is added.

Shutdown remains terminal and returns its cached result on subsequent calls,
including an incomplete result. This change does not add retry or resume of the
shutdown procedure. Pool requests racing past the closed resource registry are
rejected with PoolShutdownError; new calls rejected earlier by Runtime retain
RuntimeShutdownError.

Use the existing controlled process-replacement procedure. Reverting the source
change needs no data rollback, but restores the resource leak and false-completion
risks. Metrics.snapshot behavior is unchanged in this unit (E03 is deferred).
