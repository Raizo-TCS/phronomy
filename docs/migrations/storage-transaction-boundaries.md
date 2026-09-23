# Storage transaction boundaries (Refactor 34)

Update core and the SQLite/PostgreSQL reference adapters together. No data
migration is required. The public method signatures, eight repository accessors,
required capability keys and stored record formats are unchanged.

## Explicit nested calls

Nested `Backend#transaction` and `Persistence#transaction` calls on the same
backend and synchronous execution context now have savepoint semantics.

```ruby
persistence.transaction do |outer|
  outer.contents.put_text("keep if outer succeeds")
  begin
    persistence.transaction do |inner|
      inner.contents.put_text("discard on inner failure")
      raise "inner failure"
    end
  rescue RuntimeError
    # Inner changes have already been rolled back. Re-read conditions needed
    # for subsequent work through the valid outer scope.
    outer.contents.put_text("outer may continue")
  end
end
```

Earlier SQL reference versions joined the outer scope. Catching the inner error
could preserve inner writes. Such writes are now rolled back. A successful inner
call does not commit independently; failure of the outer call rolls back both.
The same exception object is propagated after rollback, including
`ActiveRecord::Rollback`, which ActiveRecord itself normally consumes. Catch
that exception outside the Storage/Persistence block if continued execution is
intended. No separate database connection is introduced.

## Invalid Journal batches and database failures

The SQL references now validate and serialize every record and normalize the
expected position before the first write. An invalid second record cannot leave
the first inserted with an unchanged Journal head. Record IDs from a rejected
input batch can be retried with valid data.

This is an input-validation guarantee. A database failure after writing must
escape the current transaction scope. To continue outer work, establish an
explicit inner scope before the operation, and catch outside that inner scope.
Do not catch and ignore database errors inside the failed scope. Unknown commit
outcomes still require existing reconciliation rules, not blind retries.

## Active Agent execution updates

InMemory now enforces the same active-owner exclusion during update as SQL.
Trying to reactivate an Agent execution while a different execution for that
Agent is active raises `Storage::ActiveExecutionConflictError` at the raw boundary
and does not advance the revision or replace the record. The domain-facing
repository retains its existing error translation. Team terminal execution
reactivation remains forbidden.

## Backend authors and remaining migration

Run `phronomy/testing/persistence_contract`, including `a Persistence backend`,
against each real backend. Explicit nested calls must preserve block results,
exception identity, inner rollback and outer atomicity across repositories.
SQL integrations additionally exercise physical constraints, concurrent writers,
connection failure and durable reload; mocked connection responses do not cover
those guarantees.

Records/Streams/Blobs, failed-view enforcement and explicit non-local block-exit
handling are later S2b work. Do not use `return` / `break` / `throw` as portable
commit controls in the current SPI. See [ADR-057](../decisions/057-storage-transaction-boundaries.md).
