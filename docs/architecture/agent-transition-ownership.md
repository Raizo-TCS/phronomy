# Agent invocation transition ownership

## Role and scope

An Agent invocation moves between preparation, Provider calls, Tool processing,
approval suspension and completion. Three collaborators need the same policy:
AgentInvocation consumes external payloads; PhaseMachineBuilder creates the
executable state machine; AgentInvocationSessionBuilder configures FSMSession's
advance, wait and terminal boundaries. Independently maintained event lists and
transition copies could disagree about what the current phase can accept.

Refactor 39 gives that shared policy one private owner, InvocationTransitions in
agent/execution. This is Agent data in the existing transition Hash format, not
a new cross-feature DSL or Engine extension. It is not a new execution object.

## Ownership and reading order

| Owner | Responsibility |
|---|---|
| InvocationTransitions | Initial phase, declared/automatic/approval-wait states, Tool event vocabulary and ordered external transition definitions. |
| PhaseMachineBuilder | Translate those external definitions to state_machines; retain automatic state_completed transitions and synchronous entry-action validation. |
| AgentInvocationSessionBuilder | Assemble the invocation, event sink, entry actions and machine; pass shared state and transition metadata to FSMSession. |
| AgentInvocation | Apply payloads and expose the current guard predicates; use the shared Tool event vocabulary. |
| FSMSession | Generic advancement, event delivery and wait/terminal handling. No Agent-specific decisions. |

Read the policy table for legal external sources and guard priority, the machine
builder for execution mechanics, and the session builder for action wiring.
The EXTERNAL_EVENTS Hash, each transition array and each row are frozen so one
session cannot edit another session's policy. Guard lambdas contain no captured
invocation state; they inspect the context supplied at transition time.
Old private constants and the external_events factory are removed without aliases.

## Preserved event and phase contract

The six Tool events are authorized, approval_required, completed, failed,
rejected and cancelled, each with the tool_ prefix. Each moves waiting_for_tools
to evaluating_tools. LLM completion from calling_llm tries these in order:

1. callback_failed? to failed;
2. handoff_failed? to failed;
3. handoff_requested? to handed_off;
4. tool_call_pending? to starting_tools;
5. unconditional fallback to output_filtering.

Guards short-circuit. A nil context skips guarded rows and takes the fallback;
guard exceptions propagate unchanged. Each evaluation uses the latest context,
without caching a selected destination. Session applies the event payload first.

LLM failure/setup failure leads from calling_llm to failed. Tool setup failure
leads from dispatching_tools to failed, while tool_dispatch_prepared returns it
to evaluating_tools. Resume moves suspended to waiting_for_tools. Application
callback failure is accepted from the existing nine active phases only.

Automatic phases remain idle, filtering_input, building_context, starting_tools,
evaluating_tools, recording_tool_results and output_filtering. calling_llm,
waiting_for_tools and dispatching_tools wait for external events. suspended ends
a segment with halted; resume uses a fresh Session identity. The four declared
terminal phases remain handed_off, completed, blocked and failed.

FSMSession reads only the from field when determining external-event admission
and waiting. It does not execute metadata guards or choose their destinations;
state_machines does that. Known-but-undeclared and unknown events retain their
existing error behavior; context-consumed stale events retain their early exit.
The internal order of event registration now follows the shared table. Transition
order within each event, which determines behavior, is preserved. The generated
machine's private event-enumeration order is not a supported public contract.

## Verification and limits

Independent behavioral tests run on both Refactor 38 and the candidate: all 195
external-event/source-state combinations, all sixteen LLM condition combinations
including short-circuit order, nil context and guard exceptions, fifteen Session
boundaries, context-before-guard ordering, approval suspension/resume/dispatch,
and invalid source-state handling. Existing Agent, causal durability, Handoff,
Workflow and Engine tests continue to cover their collaborating behavior.

The candidate also runs the full core/integration suites, offline examples and
real SQLite, API/SPI snapshots, RBS, style, annotations and isolated gem checks.
No SQL, stored format, entry action implementation, Tool restoration, cancellation
or Coordinator sequencing is changed. The new contract tests isolate entry actions
and do not claim live Provider coverage. Live PostgreSQL/LLM and remote CI are
not executed for this candidate. The published SVG stays on applied38-01 until
user application is independently verified.

R06 remains application-pending. R07, R08/D08, R09 and R10 remain after that gate;
in particular, R09's inheritance behavior and R10's action names are not altered.
