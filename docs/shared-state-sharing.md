# Custom sharing in SharedState

SharedState can coordinate member Agents while an application owns the shared
data and the Tools that access it. The application provides one invocation-scoped
binding; SharedState owns member order, cycles, stopping decisions and final
aggregation. This Experimental extension is Unreleased.

For example, an issue-review team can share records with `category` and `status`
fields. Its search Tool accepts those fields as separate arguments instead of
forcing the application to encode every record and condition as finding text.

## Application provider and binding

A provider scopes shared resources around one synchronous team invocation. Its
binding contains an opaque store and a Tool-definition builder. SharedState
passes the store to application callbacks and does not require store methods or
a particular record schema.

For example, an application provider can open an issue board, yield its binding,
and close the board in `ensure`:

```ruby
class IssueSharing
  def open(input:, config:)
    board = IssueBoard.new
    yield Phronomy::MultiAgent::SharedState::Binding.new(
      store: board,
      tools: ->(member:, cycle:) { build_issue_tools(board, member, cycle) }
    )
  ensure
    board&.close
  end
end
```

This excerpt shows the provider boundary. The
[complete executable application example](examples/shared_state_custom_sharing.rb)
defines its store, Tool builder, member Agent, team and offline check.

The provider must respond to `open(input:, config:)` and yield exactly one
`Phronomy::MultiAgent::SharedState::Binding` synchronously during that call.
Zero yields, multiple yields or an invalid binding violate the protocol and
raise `ArgumentError`. Do not retain the block for deferred execution. The
provider owns cleanup, including failures raised by member execution or
aggregation; SharedState does not call `close` on the opaque store.

`Binding.new(store:, tools:)` accepts a callable Tool builder. The public
`binding.store` returns the opaque store, and
`binding.tool_definitions(member:, cycle:)` calls the builder. `member` is the
registered Agent class; `cycle` is the current positive cycle number. The builder
must return a Hash whose keys are Tool classes and whose values are aliases or
`nil`, using the same Tool-definition shape as the existing Agent Tool API.
Arrays are not accepted. Invalid configuration or protocol values raise
`ArgumentError`.

## Team composition and definition identity

A team selects its provider and supplies the application operations that consume
the shared store. The provider's stable ID and version identify the meaning of
its injected Tools independently from an individual member's definition.

For example, the complete issue-review example declares:

```ruby
class ReviewTeam < Phronomy::MultiAgent::SharedState
  sharing IssueSharing.new, id: "shared-issues", version: 1
  member Researcher
  max_cycles 2
  coordination "Use search_issues to inspect relevant issues. " \
               "Use record_issue to record each new issue with its category and status."
  aggregate { |board| board.snapshot }
end
```

Custom sharing requires an explicit `aggregate` block because SharedState does
not know how to read the application store. An optional `terminate_when` block
also receives that same store. Existing cycle order, stopping rules and result
shape remain in place. `config:` is provided to the sharing provider; this does
not introduce forwarding of `config:` to member invocations.

In custom mode, SharedState adds only the Tools returned by the application's
builder. It does not add `read_store` or `write_finding`, and it does not append
stored records to member prompts. The prompt consists of coordination text, the
task input and any member instruction. The member's existing Tools and aliases
remain available. Conflicting effective Tool names are rejected rather than
silently replacing an existing Tool.

Use a stable sharing ID and increment its version whenever the injected Tool
schemas or behavior change. Custom generated Agent identity incorporates that
ID/version alongside the member definition. A new store instance per invocation
does not by itself require a new sharing ID. The application must not substitute
different Tool semantics under an unchanged sharing revision.
The ID must be a nonempty String and the version must be a positive Integer.

The default mode remains available when `.sharing` is not configured. It retains
the existing invocation-local KnowledgeStore, built-in Tools, full-store prompt
behavior and instrumentation revision 1. This extension does not add a `query`
argument to the default `read_store` Tool or a search method to that store.

## Deriving an Agent with a complete Tool set

The public `Agent::Base.with_tools(definitions, id:, version:)` factory creates
an Agent subclass with a replacement Tool map and an explicit definition
identity. Agent owns preservation of its authoring settings; SharedState uses
this public operation after composing the member and application Tools. It does
not need to read Agent private settings.

For example, inside the complete example's module, a provider can supply the
entire Tool map for a derived researcher class:

```ruby
IssueSharing.new.open(input: "Review authentication", config: {}) do |binding|
  tool_map = binding.tool_definitions(member: Researcher, cycle: 1)
  derived = Researcher.with_tools(
    tool_map, id: "issue-researcher-with-board", version: 1
  )
  # `derived` is a class; no Agent instance or Runtime resource was created.
end
```

`definitions` is the complete Hash of Tool classes to aliases or `nil`; this
factory does not merge Tools or detect naming collisions. SharedState performs
those operations before calling it. A missing parent Tool is removed, and a
`nil` alias uses the Tool's own name even when the parent assigned an alias.
The supplied ID and version identify the derived definition directly.

The factory preserves Phronomy-authored model, provider, instructions,
ContextPolicy, generation settings, LLM-input hook and filters. Filter lists
are independent while configured filter and callback instances remain shared.
The original class is unchanged. This explicit factory does not change general
Agent subclass inheritance or define copying rules for application-specific
class state.

## Application search and LLM input

Application Tools own record fields and search conditions. ContextPolicy and the
existing input-validation path continue to own LLM-input selection and budget
checks. A custom provider does not become another Context engine.

For example, `search_issues(category: "security", status: "open")` in the complete
example applies both field conditions and returns matching records as JSON. A
search can leave three records in the store while returning only one match. Its
Tool parameter types and enumerations use the existing Tool schema API.

The example has no result-size cap. A broad query may still produce a large Tool
result, and this extension does not make that result optional, rewrite recorded
Tool output or bypass the final input-budget check. Applications that need
paging, compaction or another acquisition policy must define that behavior
explicitly through the existing appropriate contracts.

SharedState continues to use the member's configured ContextPolicy. The binding
does not automatically populate `before_llm_input` candidates, inspect Context
internals or manage a provider message buffer. Example 22's adaptive reader is a
separate application implementation; this extension alone does not migrate it
or remove its existing private-API dependency.

## Lifetime and verification

The provider owns resources for one synchronous invocation. SharedState does not
define a database schema, durable binding identity or process-transfer protocol
for the application's store. A live binding does not become a persisted
continuation. Custom sharing requires each member invocation to reach a terminal
state before coordination proceeds.

For example, the application file can check its store and Tools without calling
an LLM:

```sh
bundle exec ruby docs/examples/shared_state_custom_sharing.rb --offline
```

The check opens the provider, records three issues through `Tool#call`, searches
with both category and status, verifies one match and three retained records,
and verifies provider cleanup. It uses the real Tool argument-validation path.
It does not exercise the SharedState Agent loop or establish live-model,
database or multi-process acceptance.

In custom mode, SharedState releases terminal member instances through the
Agent's public `unload!` operation. A normal Agent approval wait keeps the public
`invoke` call pending. SharedState consequently stays inside the provider's
`open` block and retains its resources; it does not return a suspended result or
close the provider merely because an internal execution reaches an approval
wait. The application remains responsible for answering or cancelling approvals.

For example, when a member waits for approval of `record_issue`, the board stays
open while that invocation waits. An approval allows the Tool and member to
complete before aggregation and provider cleanup. A cancellation that ends the
member invocation also allows cleanup to run. The in-memory example's `ensure`
is scoped to the end of the invocation, not the start of an approval wait. This
is a live wait in the current process, not a way to release a Worker and restore
the board on another one.

The [SharedState integration suite](../spec/integration/shared_state_spec.rb)
separately exercises this approval lifecycle using a real Agent and fixed LLM
responses. It checks that the provider stays open and aggregation has not run
during the wait; after a public approval response, the Tool writes its record,
aggregation runs, the provider closes and the member is released. Fixed
responses verify the execution path, not a live model's Tool-selection behavior.

The lifecycle guard also detects a custom `invoke` override that returns a Hash
with a suspended status before reaching completion. That exceptional early
return raises `SharedState::MemberLifecycleError` with `reason: :suspended` and
stops coordination before later members or aggregation. It is not the behavior
of normal Agent HITL. SharedState does not approve, deny, cancel or unload the
pending execution on the application's behalf. Providers handling this case
must decide whether to retain their resources; merely retaining a binding adds
no SharedState resume operation.

`MemberLifecycleError#reason` also reports `:release_failed`. The error exposes
`agent`, the available `result`, `primary_error` and `release_error`. A failed
release preserves the Agent reference and both failure details when invocation
and release fail together, so the application can inspect the original failure
and decide whether to retry release. The provider's `open` scope can rescue this
error before its cleanup policy runs. Rescuing a coordination failure inside
`open` does not turn the invocation into success: SharedState still reports the
failure if the provider returns normally.

To run the team from an application, configure Phronomy's LLM backend normally,
set `PHRONOMY_EXAMPLE_MODEL` to that backend's model ID before requiring the file,
then invoke `SharedStateCustomSharingExample::ReviewTeam.new.invoke(task)`.
The example's fallback model name is a placeholder, not a remotely available
model. A DB-backed provider may replace the example's in-memory board, but its
transactions, isolation and recovery behavior remain application responsibilities.
