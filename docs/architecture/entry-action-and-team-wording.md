# Entry-action names and Team task wording (R10)

## Scope

Refactor 44 follows applied Refactor 43, core
`5c4c039273eb2324fcc9e9943ccf40bd1ffb3abd`. It changes two private action names
and two Team-generated strings. No new production class, alias, state, event,
loader rule, persistence format or public method signature is introduced.

## Action names describe their local work

| Existing phase | Private action | Work |
|---|---|---|
| `filtering_input` | `apply_prepared_input_action` | Read `phronomy_filtered_input` from the prepared config and install it on the invocation. |
| `building_context` | `build_runtime_chat_action` | Build a Chat with the prepared projection's settings and apply its instructions, Tools and messages. |

These replace `filtering_input_action` and `building_context_action` respectively.
Their bodies, arguments, return values, exceptions and ordering are unchanged.
Input filtering and context preparation remain with the existing preparation
owners; these actions do not repeat that work. The first action keeps its unused
Agent argument so the existing bound-action construction remains unchanged.

Phase names, transition guards, callbacks and saved resume phases remain intact.
A phase is an existing lifecycle boundary; an entry-action name describes the
operation performed at that boundary. Renaming phases would require a separate
compatibility design for observation and saved executions.

## Team tasks and completion handles

| Surface | Before | After |
|---|---|---|
| `finalize.summary` parameter description | `TaskResult summary` | `Task generation summary` |
| Newly committed `enqueue_task` result | `TaskResult #N enqueued: ...` | `Task #N enqueued: ...` |

These are observable text changes, not solely internal renames. The description
is sent to the LLM. The enqueue response is saved in Team operation metadata and
subsequently supplied as a Tool result. The task description supplied by the
caller is not rewritten. Tool names, argument names, types, optionality, task IDs,
batch ordering, queue contents and cancellation behavior are unchanged.
`Phronomy::TaskResult` continues to mean the asynchronous completion handle.
Team integration examples now use `Task A/B/C` for business-task descriptions.

The existing operation-ID deduplication returns the stored result verbatim.
Already committed legacy `TaskResult #...` results therefore remain unchanged
on replay, including after restart. This change does not migrate old records,
rewrite Journals or reformat results during readback. Reusing an operation ID
with different arguments still fails the existing identity check.

## Verification and limits

The package checks the existing Agent transition and Chat contracts, durable
Team execution, full core/integration suites, offline examples, real SQLite,
API/SPI, types, style, gem loading and independent application. One additional
regression verifies legacy response replay after restart, no repeated writes,
the TaskResult return type and argument-identity rejection. It also passes on
the applied baseline.

Separate processes capture a committed finalize operation before its Agent
settlement and resume it using the other version, in both directions. Stored
operations remain byte-equivalent at the value level, tasks are not duplicated,
and the expected two remaining Provider calls occur. These are stubbed Provider
checks with an InMemory snapshot; they are not live-LLM or cross-version SQL tests.

The review exposed an existing [Tool schema recording gap](tool-schema-recording-gap.md)
on RubyLLM 1.16.0. R10 does not repair it or weaken definition checks. Successful
continuation here does not prove that incompatible parameter definitions are
rejected. The generated parameter description changes, while the current saved
Tool definition omits parameter details.

R09 is applied and verified. R10 is implemented and locally verified, pending
application verification. The newly discovered schema issue remains open, so
closing the original R/D inventory must not be described as absence of defects.
