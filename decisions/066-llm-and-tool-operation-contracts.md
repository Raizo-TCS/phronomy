# ADR-066: LLM and Tool operation contracts

Status: Accepted for the r8 unit 6 candidate; application verification is separate.

C09 owns model-turn values, operation invariants, usage and failures. C06 owns Tool
requests, schemas, validation, authorization and execution rules. Shared usage is
not a placement criterion. SDK wire parsing/rendering and callback interception
remain in the RubyLLM backend. Agent owns context, approval, durable execution and
recovery; AsyncClient submits the complete backend operation to Execution.

Tool::Base becomes independent of RubyLLM::Tool. The schema used for advertisement
is also the validation source for both declaration paths. C09 depends only on C06
value/schema semantics, never executable Tool instances. Protected hooks allow a
minimal independent backend; public complete/stream enforce the common contract.
No forwarding namespace or legacy SDK-shaped adapter SPI is retained.

Consequences and compatibility are recorded in
[unit 6 architecture](../architecture/r8-unit6.md) and
[unit 6 migration](../migrations/r8-unit6.md). Existing pending execution schema
comparisons remain strict; deployment must account for changed Tool definitions.
