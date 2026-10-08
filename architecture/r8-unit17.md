# r8 unit17: Domain settings consumption

This responsibility-only refactor is based on applied unit16, commit
`fb551e1a1a8334b2547ecad126dd9c152c1b0f8c` (tree
`1ddb3b0e3f4eb97c1738ad02f9035eeefa180c90`). It addresses B08.

## Values and composition have different owners

Agent::Settings owns Agent option values and the existing stream callback error
policy validation. WorkflowSettings owns the Workflow progress limit and optional
state repository. They contain actual domain values, never the application
Configuration object. Their readers do not select a concrete adapter or backend.
Configuration remains the application-facing facade and composes these values;
its existing readers, writers, default values and zero-argument constructor remain.
The application composition boundary supplies the defaults and lazy providers.

The existing MultiAgent::Store receives a provider for the optional configured
store. It does not construct a fallback. Team still falls back to its fresh-store
factory; Orchestrator still permits no coordination store unless durable children
require one. Explicit stores and execution participants keep their priority.
A single store reader does not require a separate MultiAgent settings class.

Logger reads use the existing neutral RuntimeSettings. Agent authorization pool
size and queue capacity belong to the execution connection, which reads them
when submitting authorization work to the owning Runtime. Agent retains timeout
selection, approval evaluation, result interpretation, and operation supervision.
The private ExecutionEnvironment#submit_authorization operation separates those
resource choices from ToolInvocation. Generic Tool submission is unchanged.

## Preserve read timing without notifications

Each existing read remains at its previous execution boundary. Providers are
bound without evaluating Configuration or starting Runtime resources. A read
resolves the current domain values; it does not subscribe, poll, cache, or push
changes. There is no observer, change event, background task, version counter,
refresh loop, or new in-flight reconfiguration guarantee.

The existing read positions and short-circuit rules remain significant:

- Agent class model fallback is read when model is requested. Explicit class
  models keep precedence. Already-created Agent stores are not replaced.
- Hooks and LLM adapter operations are read at the existing input preparation,
  identity check, and call sites. Hook order and validation remain Agent rules.
- Workflow limits are read when starting or resuming execution. An admitted
  execution retains its limit; a changed global default does not update it.
- Explicit nil, per-invocation overrides, configured stores, and fresh fallback
  stores retain their existing meanings. No new defaults are created on reads.
- Configuration copies duplicate the domain value containers while retaining
  injected component identities, preserving nested scoped overrides and reset.

The new domain value types are internal, grouped by responsibility rather than
one class per setting. Public Configuration continues to offer the same settings;
applications do not need to inject every value manually. Its private instance
variables and internal containers are not an application extension API.

## Verification and limits

Regression checks cover lazy boot and direct Configuration loading, nested scope
restoration after failure, reset, component identities, nil, class and invocation
overrides, hook read timing/order, Workflow admission-time limits, persistent
Agent stores, and the distinct Team/Orchestrator fallback behavior. Execution
connection tests verify authorization resource options and owning Runtime.
Existing failure-policy/logging tests configure values through public writers
instead of mocking the old composition getter. RBS records the new internal
boundaries without erasing domain operation types.

AST gates reject application Configuration references from Agent, Workflow, and
MultiAgent domain code, including literal reflective access. They also reject
pool sizing in domain code. These are targeted regression checks, not a proof of
all dynamic dependencies or a whole-framework completion claim.

B07 remains applied. F01 durable Workflow children and other feature work are
outside this change. There are no storage schema or public operation changes.
