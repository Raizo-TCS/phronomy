# Cleanup audit migration

This cleanup removes redundant internal operations and old public entry points
whose behavior is already provided by a current operation. Applications must
use the current names; the removed names have no compatibility aliases. Current
record writers are unchanged. The subsequent [legacy-format cleanup](legacy-format-removal.md)
also removes old read fallbacks and explicitly retires two data-conversion
entry points. It does not rewrite existing stores.

For example, an application checking whether Runtime resources were released
uses `cleanup_complete?` on the result returned by `Runtime#shutdown`. The
removed `success?` method delegated to that same predicate.

## Runtime cleanup completion

Use `cleanup_complete?` to determine whether Runtime-owned resources have stopped.
Use `clean?` only when the application also needs a graceful, error-free shutdown;
that stricter predicate is retained and is not a replacement for `success?`.

Before:

```ruby
result = runtime.shutdown
resources_released = result.success?
```

After:

```ruby
result = runtime.shutdown
resources_released = result.cleanup_complete?
```

The same replacement applies to a shutdown result returned by
`Runtime.reset_default!`. Existing reset guards still reject incomplete cleanup.

## EventLoop reentrancy errors

Rescue `Phronomy::EventLoopReentrancyError` when a synchronous operation would
block the EventLoop control thread. Framework operations already raise this
class. The removed `SchedulerReentrancyError` was an empty subclass and did not
add a distinct failure or recovery behavior.

Before:

```ruby
begin
  Phronomy::Diagnostics.assert_not_in_event_loop!
rescue Phronomy::SchedulerReentrancyError => error
  warn error.message
end
```

After:

```ruby
begin
  Phronomy::Diagnostics.assert_not_in_event_loop!
rescue Phronomy::EventLoopReentrancyError => error
  warn error.message
end
```

Ruby rescue matches a class and its subclasses, not its parent. The old rescue
above therefore did not catch a directly raised `EventLoopReentrancyError` even
before this cleanup. The current error name describes the actual failure.

## Internal operations

Internal cleanup keeps behavior at its owning boundary. Context item factories
call the protected `ContextPolicy#estimate_tokens` extension operation directly.
Tool approval requests obtain one display projection and snapshot its arguments
and facts in the public approval Item.

For example, an application that renders approval details continues to use
`ToolApprovalRequest::Item#arguments` and `#facts`; it does not need the removed
internal `ToolInvocation#display_arguments` and `#display_facts` getters. The
public `Tool::Base#approval_display` extension operation remains available.

The cleanup also removes the unused internal `AgentInvocation#streaming?`,
`RecoveryRules.subject_key`, and `Execution#__while_open` and
`Execution#__cancellation_token` methods. Scope-owned operations used by result
composition remain in `ExecutionScopeState`. Five completed scripts for migrating
the repository's own test sources are removed. The subsequent legacy-format
cleanup separately retires the pre-S3 migration API and old Result JSON converter.

`JournalProjection#llm_call_records` and
`LLMInputManifest#referenced_content_refs` remain available. Lack of calls from
the repository does not make an application-facing operation removable.
