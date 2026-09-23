# GeneratorVerifier ownership and event contract

## Role and problem

GeneratorVerifier exposes the draft/review/retry pattern. An application supplies
two Agent classes, prompt builders, optional result parsers and convergence
settings. invoke runs the Workflow and returns the existing Result, optionally
raising LowConfidenceError. Agent completion arrives as Workflow events; Workflow
entry actions return context immediately rather than awaiting Agent Tasks.

R08 and D08 describe the same issue: a 199-line build_workflow mixes the graph
with Agent startup, response parsing/normalization and failure notification.
Nested PipelineState also occupies the public facade's source file. Separating
only the file without removing receiver-to-facade private calls would leave the
responsibility problem in place.

## Owners and reading order

| Owner | Responsibility |
|---|---|
| GeneratorVerifier | Public settings and Result; cached Workflow assembly, invocation, default JSON parser fallbacks and final confidence/raise policy. |
| GeneratorVerifier::WorkflowBuilder | Draft/review/finalize/failed graph, request IDs, prompt creation, Agent startup and convergence guard. |
| GeneratorVerifier::AgentResultReceiver | Separate draft/review payload conversion, common terminal-event classification and failure notification to the supplied Workflow. |
| GeneratorVerifier::PipelineState | Existing Workflow fields, request correlation, stale/duplicate rejection and EventLoop-owned state mutation. |

The last three constants are private. WorkflowBuilder and AgentResultReceiver
are new internal classes; PipelineState is the existing class moved with its
body and canonical name unchanged. The implementation lives in three files under
generation/generator_verifier. The public facade and Result keep their names and
locations; no loader changes or compatibility aliases are introduced.

The initial D08 sketch suggested multi_agent/generator_verifier_workflow.rb.
Since the prior layout work established generation as this pattern's owner,
the internal files now stay there instead of creating a second feature owner.
The new directory adds a module in directory-based analysis, not a public API.

WorkflowBuilder#build reads as a graph: named entries, then ordered transitions.
start_draft/start_review describe request preparation and dispatch. The receiver's
draft_payload and review_payload retain different meanings. Their common listener
has only the two internally selected phases; it is not a public configurable
pipeline. It shares the same terminal/error rules rather than combining response
formats into an options-driven generic parser.

Default parsers remain explicit callables captured by the facade. Clamp and
citation normalization move to their receiver owner. The old __send__ calls back
to facade helpers disappear. The existing private Agent event-sink entry point
is still called via send; changing that cooperation API is outside this scope.

## Preserved ordering and failure contract

- Each Agent is constructed once, lazily during the first successful Workflow
  build. The cached Workflow and Agent instances are reused. Each invoke gets a
  fresh Workflow context. No locking or new concurrency policy is introduced.
- Each request gets a new UUID and a merged context before prompt construction.
  The listener captures that request ID and the context's stable Workflow ID.
  Workflow closures see the completed Workflow assignment before any entry runs.
- Entry actions start asynchronous Agent work and return next_state, never a
  TaskResult. Inline completion remains valid because signal queues a Workflow
  event. Unknown/nonterminal Agent events are ignored.
- done parses output, normalizes the phase-specific payload and signals the
  matching completed event. StandardError from parsing, normalization or success
  notification is signalled as the corresponding failed event with the same
  exception object. Failure-notification exceptions are not retried or wrapped.
- error/timeout/cancelled use the payload error or the same phase-specific
  fallback message. approval_required remains a pipeline failure. A false return
  from signal is returned without a retry or a new failure event.
- PipelineState accepts only the current request ID. It clears the accepted ID,
  increments iteration after draft completion, appends feedback after review,
  and consumes old/duplicate results before any transition. The receiver does
  not mutate context or add its own deduplication; stale done payloads can still
  be parsed before the state rejects their correlated event.
- Review completes when both the lower normalized score meets threshold and
  approval is literal true, or when the iteration limit has been reached.
  Otherwise it returns to draft and passes the last feedback to its prompt.
- Final Result trust remains confidence >= threshold. At the iteration limit,
  high confidence with approved=false can therefore still produce trusted=true.
  A nonpositive limit still executes one draft/review cycle. These are observed
  existing semantics, not behavior fixes hidden in this extraction.

Public initialize/invoke parameters, Result fields/trusted? alias, parser
fallbacks, score/citation normalization, error messages and PipelineState fields
remain unchanged. Agent/Workflow/Engine/Storage behavior and SQL are not modified.
Private clamp/normalize_citations implementations relocate; private overrides are
not treated as additional supported public APIs.

## Verification and trade-off

Thirty-nine behavior examples pass unchanged on Refactor 40 and the candidate.
They cover inline completion, ignored progress, pending Task returns, both phases'
error/timeout/cancelled/approval failures, parser and notification failures,
request correlation, duplicate/old callbacks, clamping, literal approval, final
trust, iteration limits, caching, fresh state and config forwarding. Existing
delayed-callback and WebMock integration examples cover the real Workflow path.

A separate process comparison preserves public methods, parameters, constants,
Result shape, the private state name/field schema/defaults and Runtime inactivity.
Stable/Beta snapshots do not list GeneratorVerifier, so this explicit comparison
supplements those existing gates. Core/integration/examples/real SQLite, type,
style, annotations and isolated gem checks are included in distribution evidence.
Live PostgreSQL, live LLM, candidate CI and performance are not run for this scope.

The facade is 369 -> 118 lines. Workflow definition is 199 -> 34 lines, with a
12-line facade assembly method. The three internal files are 112/89/57 lines,
for 376 total, seven more than before. Two new classes and one moved class cost
additional files; they give graph, receiver and state independent reading units.
Directory-level dependency counts increase with that physical partition; cycle
membership is unchanged. This is responsibility separation, not cycle removal.

Refactor 41 is applied and independently verified at core e87eb77f, tree
14dc8a546a4fd96e19e0713f7480ca2efa3c331a. All nine files and the full tree match.
R08/D08 is closed. The published diagram is applied41-01. R09 and R10 remain.
