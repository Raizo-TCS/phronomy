# Agent configuration and Tool binding (R09, first slice)

## Role and boundary

Agent::Base is the public declaration and lifecycle facade. Before tools are
advertised to an LLM or installed in a runtime chat, its prepare_tool_class hook
selects the Agent's alias and result filters for the original Tool class.
ToolDefinitionSet and runtime projection installation use that same hook.
MultiAgent::Orchestrator overrides it, calls super, then adds subagent context.

Previously the hook also generated both decorator subclasses and bridged custom
asynchronous results, including cancellation and physical completion. Refactor 42
extracts that mechanism into Agent::ToolBinding in agent/tool_execution. Base
retains the selection hook and its invocation keyword for Orchestrator cooperation.
ToolBinding takes an explicit Tool class, alias and filter list; it holds no Agent
reference and does not call private Agent methods back through send.

| Owner | Responsibility |
|---|---|
| Base / Filterable | Select the original class's alias and ordered class, instance and scoped filters. |
| ToolBinding | Construct alias/result-filter decorators, preserve effective Tool names, and bridge custom async results. |
| Capability::Base / ToolExecutor | Default Tool call protocol and physical execution. |
| ToolInvocation | Validation, authorization, execution supervision and state restoration. |
| Orchestrator | Capture subagent parent/config/knowledge context after Base preparation. |

There is one new internal class and one production file. ToolBinding is marked
@api private, like other Agent implementation collaborators; it is not a new
supported application API. No loader change, mixin, alias or public signature
change is introduced. Definitions, approval, durable schemas and stored Tool
state are unchanged.

## Preparation and reading order

Base first returns non-Class values unchanged. For classes it constructs the
alias binding, then resolves filters, then prepares the filtered class. This
order preserves subclass creation before filter selection. With neither alias
nor filters the exact original class is returned. With an alias and no filters,
the alias subclass is returned without instantiating a Tool.

ToolBinding#prepare reads the effective name and the call_async method owner,
then defines the synchronous decorator and, only when needed, the custom async
decorator. filter_async_result registers physical and logical completion in that
order. propagate_failure and complete_filtered_result separate terminal outcomes.
The methods express one level below their operation names rather than leaving
the whole callback protocol inside Base.

The original Tool class remains the scoped-filter key even when an alias creates
a subclass. Each preparation captures a newly collected filter list; it does not
cache generated classes or deep-copy filter objects. Later registrations affect
later preparations. The synchronous call passes the original args/keyword values
to super and applies class, instance and scoped filters in that order, with the
effective name and original args. Filter exceptions propagate without ToolError
wrapping by this decorator.

## Asynchronous contract retained

- If call_async is owned by Capability::Base, leave it inherited: its ordinary
  execution path reaches the decorated call. A second async filter wrapper would
  apply the same filters twice.
- Any other method owner, including an inherited custom implementation, receives
  the custom async decorator. It forwards args/kwargs to super and wraps the
  returned operation in PhysicalCompletionTask. It does not wait for completion.
- Preserve logical completed/failed/cancelled status, values and error identity.
  Failure skips filters. A filter StandardError fails the derived result with
  that same exception. A synchronous startup exception still escapes call_async.
- With on_physical_complete support, forward that signal independently of the
  logical result. Logical cancellation/failure must not fabricate physical
  completion while the source is still working. Physical completion can precede
  the logical callback or already be true when the listener is registered.
- Without that signal, mark physical completion before settling the derived
  result, including filter failure. Listener registration remains physical first,
  logical second, so already-settled operations are handled by existing callbacks.
- Cancelling the derived result does not cancel the source. A later successful
  source completion can still execute result filters, while its derived status
  remains cancelled. This is existing behavior, not a new cancellation guarantee.

No retry, additional cancellation propagation, thread/pool policy or physical
completion guarantee is added. The source signal still describes source work,
not a new synchronization boundary around the filter callback itself.

## Agent declaration inheritance as currently implemented

Do not infer one uniform inheritance rule from the word "configuration". The
following describes current compatibility behavior; Refactor 42 does not change
the DSL methods. Parent reads are live lookups, not snapshots taken at subclass
creation.

| Declaration / getter | Child without an own value | Own value / special behavior |
|---|---|---|
| model | Global configuration.default_model; does not read parent's model | Truthy setter, nil/false are reads. Global changes remain visible until an own value is set. |
| instructions | Parent instructions, including the same Proc or template object | Text or block replaces the own value. nil without a block is a read, not a clear. |
| provider | Parent provider | Truthy setter; nil/false read. |
| tools | Parent tools array by reference | A Hash replaces the own class list. An empty Hash is an explicit empty list. nil reads. |
| tool_aliases | Parent aliases merged with own aliases | Alias values are stringified; nil entries are omitted. A child nil alias or empty tools list does not erase inherited aliases. |
| context_policy | Parent policy object, ultimately ContextPolicies::Default.instance | Exactly one ContextPolicy object replaces it. nil is invalid, not reset. |
| temperature | nil; does not inherit | Truthy setter; zero is accepted; nil/false read. |
| max_iterations | 10; does not inherit | Truthy setter; zero is accepted. |
| cache_instructions | nil; does not inherit | nil reads, false is an explicit value. |
| max_output_tokens / context_window | nil; do not inherit | nil reads; setter uses to_i. |
| agent_definition | Raises until that class declares identity/revision | Each subclass requires its own definition; this is not inherited model configuration. |
| input/output/tool_result_filter registries | Empty class registry; do not inherit | Registrations append on that class. Instance filters are separate. |
| before_llm_input / _before_llm_input | nil class callback; does not inherit | Instance and global hook behavior remains separate. |

The generic Agent rule does not override specialised subclass DSL such as
Orchestrator's subagent registry. Tool/Capability declaration inheritance is also
a different contract, already covered by its configuration-inheritance tests.

The existing test description that said "normal class configuration still
inherits" referred only to instructions and was too broad. It now names the
actual checked rule. No new policy is inferred from that earlier wording.

For compatibility, retain these rules in this source refactor. Uniform parent
fallback, alias removal and copying inherited mutable values would be separate
behavior changes requiring an explicit migration decision. They can change
model/provider combinations, budgets, Tool names and application callbacks.

## Verification and remaining R09 work

Thirty-five new contract examples run against both the unchanged Refactor 41 and
the candidate. They exercise selection/alias order, names, filter ordering,
forwarded object identity, default/custom async behavior, logical/physical
completion, cancellation and DSL inheritance. Existing Tool definition, approval,
Orchestrator and full integration suites cover the cooperation paths.
The release, API/SPI, RBS, style, isolated gem and examples gates are recorded in
the distribution. Candidate remote CI, live PostgreSQL, live LLM and performance
are not measured by this change.

This closes only the implementation candidate for R09's Tool binding separation
and records current declaration rules. R09 remains open. Its initial proposal
also named Chat construction and state mutation: build_chat,
_apply_runtime_projection_to_chat, create_agent_root!, add_knowledge and
mutate_context! still live in Base. Review their ownership and transaction/root
publication boundaries in the next slice; do not silently drop them from the
remaining-work inventory. Those methods and Orchestrator are unchanged here.

R10 remains open. Keep the published SVG on applied41-01 until this candidate is
applied and independently checked.
