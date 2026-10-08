# r8 unit22 migration

No application source or stored-data migration is required. Apply this core-only
package on unit21 commit `4525e71ca808acac9eb0302a59c32f00478a7782` and restart
using the application's existing drain/shutdown procedure.

- MCP public construction, execution, close, schema, authorization and result
  formatting APIs are unchanged.
- A completed MCP call no longer retains a cancellation callback on a shared
  caller token. A callback already taken by concurrent cancel! may still finish.
- Logical timeout does not end the SDK invocation's cancellation bridge. The
  registration is released when that invocation exits.
- If Runtime rejects transport cleanup because it has stopped, the MCP caller
  performs the existing synchronous close fallback and still receives the MCP
  cancellation outcome. This can include the transport's normal close latency.
- Warning logging uses the same configured logger through neutral settings,
  with stderr fallback when no logger is configured.

Execution, Engine and Contract source are unchanged. There are no new threads,
configuration options, timers or notification services. The existing MCP
cleanup pool remains in use while Runtime accepts work.

Custom tests that expected cancellation to reach an already-completed MCP call
should instead cancel while the SDK call is active and verify that completed
calls release their registrations. The SDK cancellation bridge helper is
private; its new subscriptions keyword is not a public application API.

Examples retain their unit6 source. Verify them against this core checkout using
PHRONOMY_PATH and restore only verification-generated lockfiles/artifacts.
