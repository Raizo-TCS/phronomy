# r8 unit22: MCP connection lifecycle

This change is based on applied unit21, commit
`4525e71ca808acac9eb0302a59c32f00478a7782` (tree
`957baf18c23ce5659c11454f3a89e893c07b2138`). It corrects two concrete MCP
lifecycle defects and removes an unnecessary application-composition reference.
It is not a new Contract or an Execution/Engine refactor.

## Ownership

| Owner | Responsibility |
| --- | --- |
| MCP Tool implementation | Translate SDK cancellation and results, own the client/transport, delimit one SDK call's notification lifetime |
| Existing Execution ResultSubscriptions | Register and remove explicit-cancellation callbacks |
| Existing Execution/Engine | Admit and execute cleanup work, reject submissions after shutdown, drain accepted work |
| Neutral RuntimeSettings | Supply the currently configured common logger |

The production change is confined to `lib/phronomy/tools/mcp.rb`. Execution,
Engine, Tool Contract, runtime composition, public signatures and storage
formats are unchanged.

## Cancellation bridge lifetime

Previously each SDK call registered a callback directly on its supplied
CancellationToken and retained it until that token was cancelled or collected.
Completed and failed calls therefore accumulated callbacks when a caller reused
a token. A later cancellation also touched obsolete MCP cancellation handles.

Each call now owns an existing ResultSubscriptions collection, registers its
bridge with explicit_cancellation, and closes the collection in ensure. This
also covers SDK errors, malformed responses and cleanup failures. Other
subscribers on the same token are preserved.

The lifetime is the concrete SDK invocation, not its caller-facing TaskResult.
If OffloadPool settles a timeout while SDK work is still running, a subsequent
explicit cancellation must still reach that work. No timer, deadline promotion,
polling thread or TaskResult completion callback is introduced by the bridge.

ResultSubscriptions.close does not revoke a callback already taken by a
concurrent cancel!. Such a callback can finish after the SDK call returns. It
only captures that call's MCP cancellation handle, whose cancellation is
idempotent; it does not look up the next client or cancel a replacement call.
This preserves the existing Execution notification semantics.

## Cleanup rejection at Runtime shutdown

After SDK cancellation the MCP instance detaches the old client before it can
be reused. Normally its transport is closed on the named Runtime cleanup pool.
Previously the synchronous fallback handled queue saturation and a stopped
pool, but not RuntimeShutdownError raised before pool acquisition. In that
case close was skipped and the shutdown error replaced the cancellation result.

MCP now applies its existing synchronous close fallback to RuntimeShutdownError
too. It does not reopen Runtime, create another worker, retry the Tool call or
relax Engine admission. Accepted cleanup remains owned and drained by Runtime.
MCP attempts to close a rejected transport and preserves the existing best-effort
close behavior if the SDK's close itself raises.

## Logging and validation

MCP warning output reads RuntimeSettings.current.logger once per warning and
retains the existing stderr fallback. It no longer reaches the application
Configuration facade just to obtain this common value. Logger choice is still
made by application configuration; no new setting or provider is introduced.

Focused regressions cover repeated success, SDK/response failures, explicit and
already-delivered cancellation, timeout before physical completion, cancellation
racing completion, accepted cleanup, stopped Runtime, rejected submission,
failing close and both logger paths. Concurrency tests use barriers and an
injected monotonic clock rather than timing-dependent sleeps.

These are lifecycle corrections, not merely file moves. They require no data
migration or examples source change. Deferred features, including durable
Workflow children, remain outside this change.
