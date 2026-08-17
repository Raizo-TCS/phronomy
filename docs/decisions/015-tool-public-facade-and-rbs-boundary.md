# ADR-015: Public Tool Façade, Extension SPI, and RBS Contract Boundary

## Status

Accepted.

## Context

Phronomy has accumulated two related API-maintenance problems:

1. Application-defined Tools are implemented by subclassing the internal-taxonomy
   name `Phronomy::Agent::Context::Capability::Base`, even though the product
   concept exposed to users is simply a Tool.
2. The gem ships almost no RBS signatures, so the distinction between
   application APIs, extension SPIs, and private implementation objects is not
   machine-readable.

At the same time, Phronomy already has compatibility mechanisms that must remain
canonical: runtime behavior, focused contract tests, YARD `@api`
classification, feature stability documentation, and API snapshots. RBS must not
become a second specification system that silently promotes internal behavior to
a compatibility promise.

The LLM call boundary also needs an explicit extension contract. Configuration
already allows replacing `llm_adapter`, and `LLMAdapter::Base` requires
implementations of `complete` and `stream`, but those methods were previously
classified as private. The current Agent pipeline still materializes a
RubyLLM-shaped chat/runtime object before invoking the adapter; formalizing this
SPI therefore must not be described as a provider-neutral replacement of the
whole materialization pipeline.

## Decision

### Public Tool authoring façade

The application-facing Tool authoring name is:

```ruby
Phronomy::Tool::Base
```

The existing implementation class remains:

```ruby
Phronomy::Agent::Context::Capability::Base
```

`Phronomy::Tool::Base` is an exact constant alias to that same class object. It
is not a subclass and the implementation source is not moved.

This preserves:

- class identity;
- Tool DSL class-instance state;
- built-in Tool inheritance;
- existing user code using the longer namespace;
- existing serialization/debugging behavior based on the implementation class
  name.

Consequently, `Phronomy::Tool::Base.name` intentionally remains
`"Phronomy::Agent::Context::Capability::Base"`. If a future public contract
requires the runtime class name itself to become `Phronomy::Tool::Base`, that is
a separate migration decision.

`Phronomy::Tool` means the authoring API. `Phronomy::Tools` continues to mean
Phronomy-provided built-in Tool classes.

### Extension dependency direction

Phronomy owns the interfaces that external implementations depend on:

```text
Phronomy Core ──────→ Phronomy-owned public contract
External extension ─→ Phronomy-owned public contract
External extension ─→ extension-specific dependency
```

External adapters/backends must not need private Runtime execution machinery
such as EventLoop, FSMSession, AgentInvocation, ExecutionCoordinator, or private
OffloadPool operation state merely to implement their domain contract.

Synchronous work requiring an operating-system worker Thread is submitted by
Phronomy to OffloadPool. The caller-facing completion handle is
`Phronomy::Task`; OffloadPool-specific queue/worker/abandonment state remains
private execution machinery as defined by ADR-010.

### LLMAdapter SPI

`Phronomy::LLMAdapter::Base` is a Beta extension SPI.

The external implementer contract is centered on:

```ruby
def complete(chat, message, config: {})
def stream(chat, message, config: {}, &block)
```

The adapter or provider client owns provider transport timeout, retry, backoff,
and rate-limit behavior.

Phronomy owns the asynchronous bridge:

```text
complete / stream
       ↓
complete_async / stream_async
       ↓
OffloadPool
       ↓
Task
```

External adapter implementations do not implement or depend on OffloadPool,
EventLoop, FSMSession, or other Runtime internals.

This SPI is the call boundary around the currently materialized chat/runtime
object. It does **not** make the entire pipeline provider-neutral. In particular,
this ADR does not remove `RubyLLMMaterializer`, introduce provider-neutral
request/response objects, or claim that arbitrary LLM client libraries can
replace RubyLLM without additional architecture work.

### RBS ownership and scope

RBS is a typed representation of contracts already established by Phronomy. The
source of API meaning remains the combination of:

```text
runtime behavior
+ YARD @api classification
+ feature/API documentation
+ focused compatibility/contract tests
```

RBS describes the resulting type shape. It must not be used in the opposite
direction to justify making an internal method public.

Initial signatures cover:

- primary application APIs;
- explicit extension SPIs;
- stable/common completion and configuration types needed to connect them.

Private implementation classes are not exhaustively signed.

Dynamic/external boundaries may use `untyped` where the framework does not own a
stable type shape. Phronomy-owned contracts such as Task result flow,
Persistence SPI methods, IDs/revisions, and documented fixed method arguments
should be typed where practical.

### Third-party RBS ownership

Phronomy does not vendor placeholder signatures for RubyLLM or other third-party
gems merely to make its own signatures validate. If a third-party type is not
available or is too unstable, the Phronomy-owned boundary uses an appropriate
`untyped` type until an authoritative signature is available.

### Validation and source dependency checks

RBS validation runs in a dedicated CI job so RBS tooling does not change the
Ruby 3.2 runtime support contract.

RBS verifies type/contract dependency shape. It does not prove Ruby source
`require` or constant dependency direction. Existing lightweight architecture
regression specs remain the appropriate place for source/runtime dependency
rules when such checks are needed.

Steep/full implementation type-checking is not introduced by this ADR.

## Consequences

- Tool authoring becomes shorter without moving the implementation class.
- Existing Tool definitions remain source-compatible.
- The alias has a deliberately different user-facing name and runtime
  `Class#name`; that distinction is documented rather than hidden in API
  snapshot machinery.
- `LLMAdapter::Base#complete` and `#stream` become explicit Beta extension
  contracts while async execution stays framework-owned.
- RBS can describe external extension boundaries without exposing private
  Runtime machinery.
- Public API review gains one additional artifact (`sig/**/*.rbs`) but does not
  gain a second semantic source of truth.
- A future provider-neutral LLM architecture, genuine native-async backend SPI,
  or implementation-class rename requires a separate ADR rather than being
  smuggled into signature work.
