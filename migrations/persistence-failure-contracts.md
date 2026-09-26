# Migrate the domain Persistence failure contract

This change intentionally changes the exception classes exposed by domain
Persistence operations. Apply it together with application rescue-clause updates;
there is no compatibility alias. Public method arguments, return values and
backend SPI 2 do not change.

## Application and domain repository callers

For calls through `Persistence`, its eight repositories, Agent, Team and Workflow,
use the upper contract:

| Previous category | New category |
|---|---|
| `Phronomy::Storage::ConflictError` | `Phronomy::Persistence::ConflictError` |
| `Phronomy::Storage::NotFoundError` | `Phronomy::Persistence::NotFoundError` |
| `Phronomy::Storage::SerializationError` | `Phronomy::Persistence::SerializationError` |
| `Phronomy::Storage::UnsupportedBackendError` | `Phronomy::Persistence::UnsupportedBackendError` |

For example:

```ruby
begin
  root = persistence.agents.load(agent_id)
rescue Phronomy::Persistence::NotFoundError => error
  # Handle the missing domain object here.
  logger.info(error.message)
end
```

`Persistence::StateConflictError < Persistence::ConflictError` identifies state,
ownership or revision contradictions raised by upper domain operations. Catch
ConflictError when the application handles both state and backend conflicts.
This subtype is not an instruction to retry: retain operation-specific retry and
recovery policies. Repository CAS/precondition rejections expose ConflictError.

Translated backend failures retain their original message/backtrace and expose
the original exception through `error.cause`. Backend constraint/resource details
remain there. `AgentBusyError` keeps its existing meaning and original cause;
only the owning active constraint/condition qualifies for that mapping.

## Backend implementations and raw callers

Do **not** globally replace Storage exception names in driver implementations or
raw `Storage::Backend`/View/Records/Streams/Blobs callers. Those interfaces still
raise Storage errors. The raw `persistence.backend` accessor exposes that same
backend. Direct `ContentStore::StoredContents` use also retains its raw failure
surface; `persistence.contents` applies the upper translation boundary.

Core domain repository conformance examples now expect Persistence errors. Raw
Storage conformance examples continue to expect Storage errors. Tests which
inject failures at the physical backend should still inject Storage exceptions;
tests mocking an already translated repository should inject Persistence errors.

## Commit uncertainty and saved data

Only the four listed categories are translated. Unknown driver/transport errors,
including IOError, and Storage::TransactionError pass through as the same object.
ContentStore::IntegrityError and existing domain errors also retain identity.
Do not classify every Persistence::Error as a known rollback, and do not add a
retry for a lost commit acknowledgement. Existing admission, transaction scope,
rollback, nested savepoint and recovery rules continue to apply.

No database migration is required. Saved records and content bytes use the same
formats. Error class names in newly saved diagnostic payloads can use the new
Persistence names. Old saved class strings remain diagnostic data; they are not
resolved as live exception constants or rewritten.
