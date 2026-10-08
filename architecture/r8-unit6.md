# r8 unit 6: C09 LLM and C06 Tool

Contract placement is determined by ownership of meaning and operations. Reuse
alone is not a reason to put code into a contract. This unit completes the scoped
LLM/Tool operation boundary; it does not complete every contract in the target.

| Owner | Meaning and operations |
| --- | --- |
| C09 LLM, `LLMAdapter` | Immutable Request, Message, Response, StreamChunk and TokenUsage; complete/stream templates; input/result/cancellation checks; public failures |
| C06 Tool, `Tool` | CallRequest, declarations, advertised schema, argument validation/coercion, authorization evaluation and execution/error rules |
| RubyLLM backend | SDK chat construction, options, message/Tool rendering, chunk/response decoding, SDK exception translation and SDK Tool interception |
| Agent | Select context, prepare executable Tools, run approval and Tool batches, consume LLM results, persist and recover execution facts |
| Execution / AsyncClient | Scheduling, cancellation signals, deadlines and worker submission; AsyncClient submits the whole LLM operation |

Tool requests are ordinary assistant Response values. They do not authorize or
execute a Tool. Only the backend knows RubyLLM's message callback and its private
interception signal. SDK Tool declarations have a rejecting execute method; an
accidental SDK auto-execution fails instead of bypassing Agent authorization.
A minimal backend needs only protected perform_complete/perform_stream hooks.
Agent does not require a Chat-like object, SDK methods or executable Tool handles
from it. Streaming returns a final Response in addition to typed chunk events.

TokenUsage and the four existing LLM failures move from the root namespace into
LLMAdapter, with no aliases. Unknown usage remains nil, distinct from zero.
ContextLengthError remains a direct Phronomy::Error; rate limiting and
authentication remain TransportError subtypes. InvalidResultError identifies
malformed results rather than a valid empty response. SDK errors retain cause;
application callback errors and cancellation retain their original identity.

`Tool::Base` no longer inherits RubyLLM::Tool. Both `param` and explicit `parameters`
(Hash/schema DSL) produce a C06 Schema. `validate_arguments` is the public, pure
preflight operation used before approval; `call` uses the same schema/rules before
execute. Legacy private type/coercion/nesting algorithms are removed. Parameters
that were advertised but not enforced by the explicit-schema path now fail before
approval or execute. See the migration document for the supported schema dialect.

SDK initialization, setters, completion and decoding run within AsyncClient's
worker operation. Cancellation is checked before and after the backend operation,
after SDK construction, and before delivering chunks. A deadline is an Execution
cancellation signal. It can settle the caller while a blocking SDK constructor is
still running; it does not forcibly stop a thread. When that constructor returns,
the cancellation checkpoint prevents starting a new provider request. Already
sent external work is not rolled back. Local input_budget uses existing model
registry metadata; live capacity discovery is not added to the contract.

Saved context materializes Phronomy Message/CallRequest values. SDK rendering
occurs later inside the backend, including structured-content JSON rendering and
opaque thought_signature metadata. Existing durable thought_signature and usage
field spellings remain readable. New Tool batch metadata stores the validated
argument snapshot alongside raw arguments so public authorization projection
compares what was approved, including coercion and intentional null. Historical
snapshots retain their explicit old decoding rule. Recovery resolution accepts a Response or its
canonical Hash, not arbitrary SDK objects. Record identities, transaction/CAS
rules, approval ownership and F0/F1/F4 classifications remain with Agent and
Persistence. No exactly-once or automatic retry guarantee is introduced.

## Architecture evidence

M47 (`llm_contract`) is retired into M15 (`llm_adapter`); the identifier is not
reused and historical diagrams remain historical. C09 is allowed to reference
C06 Schema/CallRequest. Directory aggregation also shows C09 -> Tool -> Execution,
because Tool::Base owns an execution template in the same directory as the values.
The directory gate permits that specific route; AST checks reject direct C09
mechanism references, Tool::Base consumption and SDK/Agent/Engine leaks. The full
Ruby/RBS matrix retains the route instead of hiding it. Standalone loading and a
minimal backend execution test additionally establish that C09 values do not
load Tool::Base, Agent, Engine or the SDK.

Remaining work includes Agent/MultiAgent/Workflow FSM and Runtime connections,
Workflow durable children and cross-record outcome evidence, live provider
verification, and the broader semantic review of existing dependency triangles.
