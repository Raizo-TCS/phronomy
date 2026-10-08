# r8 unit23: concrete consumer composition

This change is based on applied unit22, commit
`17cf02eb1ec0ec534b3dd8e1e64c75e13c961cfc` (tree
`dc591b3d8dfb1edace4f98e68f5e505a6c457f58`). It normalizes two concrete
composition paths identified as NC02 and NC08 in the target diagrams.
These were responsibility improvements, not demonstrated runtime failures.

## Agent Tool

The synchronous implementation previously called the application convenience
API `Agent.run_once`, which selected an ephemeral store through
`PersistenceComposition.agent`. Its asynchronous implementation already obtained
the same default through the boot-supplied `Agent::DefaultPersistence` factory.

Both paths now obtain a fresh store from that existing factory. The synchronous
path uses public Agent creation and invocation, preserving the explicit
`context: nil`, `knowledge: []`, and `on_event: nil` creation arguments that
`run_once` supplied. It forwards the same invocation options and converts the
output to a String as before. The asynchronous implementation is unchanged.

Each call still creates its own Agent and store, even when an application-level
Agent store is configured. No Agent or store is cached. Tool definitions and
instances do not acquire persistence. Cancellation propagation, asynchronous
config token priority, Tool validation, result transforms and recovery errors
retain their existing behavior.

`Agent.run_once` remains the public application convenience API. It continues to
own explicit composition; only the concrete Tool stops depending on that facade.
Calling a public composition API is not inherently invalid. Here the narrower
existing factory lets both Tool paths follow the same ownership boundary.

## LlmJudge

The scorer owns prompt construction, the public LLM Request, score parsing and
clamping, and its warning/raise policy. It no longer selects the configured
adapter or constructs `LLMAdapter::AsyncClient` inside `score`.

`runtime_composition/evaluation_defaults.rb` supplies a single factory during
normal application loading. The factory selects the currently configured
adapter and constructs the client. Installation creates no Configuration,
client or Runtime. It uses a private, one-time binding in the existing scorer
class, not a new Contract, module registry or application extension API.

Each score invokes the factory after prompt and Request preparation, at the
same point as the previous client construction. The adapter is therefore read
again after configuration updates, reset and scoped restoration. Neither the
adapter nor the client is cached by the scorer. The factory does not move client
construction onto a worker; the existing AsyncClient still offloads the whole
backend operation. No polling, notification, retry or scheduling mechanism is
introduced.

The constructor signature is unchanged. Subclasses inherit the same default
binding. Client construction/admission/provider failures remain within the
existing `raise_on_error` policy. Normal and eager loading remain resource-free
and do not load RSpec. The scorer can also be tested with an explicitly bound
client and its public Request dependency without loading composition or Execution.

## Boundaries and validation

| Owner | Responsibility |
| --- | --- |
| Concrete Agent Tool | Per-call Agent creation, invocation, cancellation forwarding and output conversion |
| Existing Agent default factory | Obtain a fresh store from the supplied boot binding |
| LlmJudge | Prompt, Request, score interpretation and scoring failure policy |
| Runtime composition | Select the configured LLM adapter and build its AsyncClient |
| Existing Execution and Engine | Submission, result completion, waiting and resource ownership |

Production changes are limited to the two consumers, the new composition file
and its explicit loader wiring. Contract source, Engine, Execution, persistence
formats, RBS and public API snapshots are unchanged. Examples need no source
change. The target diagrams remain at the applied unit22 baseline until this
candidate is applied; their two concrete composition items are addressed here.

Focused tests cover fresh construction and forwarding, default binding isolation,
score-time configuration changes, scoped restoration/reset, request/client order,
worker execution, failure behavior, inheritance and resource-free boot.
The targeted AST gate prevents either consumer from reintroducing these
composition dependencies; application composition itself remains permitted to
construct the client and public convenience API. Static graphs do not certify
all dynamically injected implementations or external providers.
