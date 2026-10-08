# R8 unit18 migration

Apply to core at unit17 commit `26792401144118f03025952aa9ec849fb16b577f`.
No examples source changes, public API updates, schema migrations or data rewrites
are required. Existing cancellation records remain valid.

Exact-execution resume with a cancelled token now records the request in the
existing Agent ledger before continuing recovery/waiting. A recording failure is
returned to the caller. Unresolved children continue to require factual resolution
and the parent remains active; cancellation receipt does not claim completion.

Cancellation metadata on the execution and MultiAgent extension is a snapshot of
its last save. If cancellation is recorded after that save, the independent Agent
ledger preserves intent until the next recovery/change reflects it. Use the
existing Agent cancellation observation instead of assuming every stored
snapshot is immediately updated.

Keep the existing stop/drain procedure when replacing running processes. This
package does not establish new compatibility guarantees for workers already
running code from another version. Reverting this source change needs no data
rollback, but reintroduces the cancellation-loss race.
