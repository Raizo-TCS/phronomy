# r8 unit 11: C04 concrete Policy and LLM connection selection

Contract placement follows ownership of meaning and invariants, not reuse.
This unit addresses review findings B01 and B02: Agent::Base selected the
concrete DefaultPolicy, and InvocationActions constructed the concrete LLM
AsyncClient. Neither choice belongs to Agent progress decisions.

| Owner | Responsibility |
| --- | --- |
| Agent::Base / C04 | Declare, validate, inherit and use a ContextPolicy |
| ContextPolicy / C05 | Context-selection operation contract |
| DefaultPolicy implementation / I01 | Existing selection strategy and token-budget allocation |
| runtime_composition/agent_defaults.rb / A01 | Install DefaultPolicy through the existing Base.context_policy DSL |
| Agent InvocationActions / C04 | Prepare the LLM request, request a client through the owning environment, track completion and deliver progress |
| Agent ExecutionEnvironment | Private connection capability to build an LLM client for the supplied adapter |
| Agent EngineEnvironment / I07 | Select AsyncClient and bind submission to the captured Runtime |
| LLM AsyncClient / I06 | Run the complete C09 operation through C13 submission; forward stream chunks and cancellation |
| LLMAdapter / C09 | Synchronous complete/stream operations and request/response rules |

Ordinary require "phronomy" installs the existing DefaultPolicy instance.
Base no longer supplies a concrete fallback; an unconfigured root raises a
ConfigurationError. No supported loading path is left unconfigured. Class
inheritance and explicit Policy overrides retain their existing semantics.
Selecting the default does not create configuration, stores or a Runtime.
This does not change DefaultPolicy's algorithm or introduce a policy registry.

InvocationActions now asks its retained environment for the LLM client.
It still reads the configured adapter at dispatch time. The Engine binding
constructs AsyncClient with itself as the existing C13 submitter protocol;
AsyncClient does not depend on the Agent environment type. No generic factory
registry, new logical Contract or public application API is introduced.

The client forwards the original TaskResult rather than replacing it. Logical
cancellation and physical worker completion remain distinct. An explicit pool
still uses Execution's existing pool-selection protocol and overrides the
injected submitter. A standalone client with no injected submitter continues
to resolve the current default Runtime at each call. Client construction
starts no Runtime resources.

For Agent calls, submission now uses the Agent's captured Runtime, matching
its sessions and other work. Replacing the default Runtime cannot redirect
only its LLM worker to a different owner. A stopped owner rejects new work
through the existing RuntimeShutdownError. Provider errors, admission failure,
chunk ordering, cancellation and completion are not translated by this change.
Public Agent/Policy signatures, manifests, durable schemas and recovery rules
are unchanged. The private AsyncClient constructor adds an optional submitter;
its private RBS uses the existing _ExecutionSubmitter interface.

## Evidence and remaining scope

Regression tests cover ordinary lazy loading, inherited/explicit Policies,
complete and streaming Agent calls after default Runtime replacement, live
adapter selection, provider worker ownership and EventLoop callback ownership.
Connection tests cover resource-free construction and stopped-owner rejection.
Async client tests cover the narrow submitter, explicit pool precedence and
physical completion after cancellation; existing failure/backpressure tests
remain acceptance gates.

Ruby AST guards reject DefaultPolicy and AsyncClient references in Agent domain
files. The Ruby/RBS graph gate separately rejects Agent domain dependencies on
llm_adapter/async and permits the binding connection. Existing lower-level
reverse-dependency rules remain intact. These checks have the same static
analysis limitations as the existing architecture tooling; they do not prove
that all logical Contract dependencies are acyclic or complete.

B01 and B02 are addressed in this candidate. C04 is not declared globally
complete. Remaining review includes C01 Orchestrator inheritance from the
concrete Agent tool, C02 Workflow execution connections and separately scoped
durable child behavior, and Recovery's domain/persistence responsibilities.
Existing domain-level explicit/configured/default store selection is not itself
a defect: concrete default persistence factories are already in composition.
