# ADR-035: Default Tool Executor Ownership

## Status

Accepted on the architecture refactoring branch as T1.

This decision assigns the default Tool execution helper to the existing
Capability implementation. The public Tool facade defined by ADR-015 remains
the same Class object with the same canonical implementation name.

## Context

`Agent::Context::Capability::Base#call_async` delegates default asynchronous
dispatch to `Agent::ToolExecutor`. The helper selects inline cooperative work
or OffloadPool submission and returns a TaskResult. It has no responsibility
for Agent state, approval, persistence, recovery, or multi-Agent coordination.

Placing this helper directly under Agent makes the Capability directory depend
on Agent execution while Agent execution also depends on Capability. The
underlying helper is part of the Tool calling contract and its standard
implementation, so its ownership should reflect that role.

Moving only the helper to `tool/` would introduce another directory cycle:
`tool/base.rb` currently aliases `Agent::Context::Capability::Base`. Moving the
canonical Tool class and changing its runtime name would require a separate
public compatibility decision.

## Decision

1. Move the helper to
   `Phronomy::Agent::Context::Capability::ToolExecutor`, in
   `agent/context/capability/tool_executor.rb`. Classify this helper as private
   API and remove the old internal constant without a compatibility alias.
2. Use the new helper from Capability Base and Agent ToolInvocation. Preserve
   the existing dispatch implementation and error messages.
3. Keep `Tool::Base` and `Agent::Context::Capability::Base` as the same Class
   object. Preserve their canonical name, DSL state, method-owner checks, and
   the public `call_async(args, cancellation_token:, config:)` protocol.
4. Keep Runtime selection, authorization and logical result ownership in Agent
   ToolInvocation. Its standard path passes Runtime and `on_full: :raise` to
   the private helper; custom Tool implementations receive the public protocol.
   Agent-as-Tool continues through its own asynchronous Agent lifecycle.
5. Keep the existing TaskResult and OffloadPool mechanisms in Engine. This
   step adds no execution manager or application registration requirement.

## Consequences and limits

The Capability directory now directly names its existing Engine dependencies
instead of an Agent-owned wrapper. The code-level algorithm and file-level
dependency graph are preserved when the moved file is matched to its source.
Directory placement changes do not imply that all larger dependency cycles
have been resolved.

Applications should use the public Tool authoring and invocation contracts.
Code or tests that directly reference the removed private Agent::ToolExecutor
constant need to follow its new internal name. The public Tool API and durable
formats require no migration, and the Context contract regrouping remains a
separate change.

## Verification obligations

Verify cooperative execution, OffloadPool dispatch, cancellation propagation,
Runtime injection, custom `call_async`, and Agent-as-Tool. Keep the existing
offload-boundary observations aligned with the moved source path. The public
API snapshot, RBS and Tool class identity must remain unchanged; Zeitwerk must
load the new helper and leave the old internal constant absent.

The implementation delivery records its actual test results separately.
