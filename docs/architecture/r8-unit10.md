# r8 unit 10: C01 MultiAgent execution connection

Contract placement follows ownership of meaning and invariants, not reuse.
AdmissionRegistry and TeamOwnershipRegistry already existed in MultiAgent.
They remain there; neither moves to Engine and no generic Registry is added.

| Owner | Responsibility |
| --- | --- |
| MultiAgent AdmissionRegistry | One synchronous coordination call per live owner; close admission and wait for admitted calls |
| MultiAgent TeamOwnershipRegistry | One live Team per ID and environment; class/store consistency, construction exclusion, shutdown cleanup |
| MultiAgent TeamCoordinator / HandoffRunner | Coordination, durable reservations, child operations, scheduling, aggregation, recovery and outcomes |
| MultiAgent ExecutionEnvironment | Private process-local connection needed by C01: registry access, owning-environment validity and submission |
| MultiAgent EngineEnvironment in runtime_binding | Runtime selection, participant registration/lookup, Runtime identity comparison and Execution submission to the captured Runtime |
| Engine Runtime | Generic participant lifecycle: close, wait under one deadline, stop resources, then finalize |
| runtime_composition/multi_agent_defaults.rb | Lazy selection of the environment and default persistence factory |

There are two registrations. Recording a Team or an active coordination call
inside a Registry is a MultiAgent operation. Registering that Registry as a
Runtime shutdown participant is an implementation connection. Previously the
Registry class methods and their callers mixed these two responsibilities.
Team/Handoff also selected Runtime directly, and Team cancellation submitted
work directly to it. The environment port separates those concrete connections.

Runtime's existing begin_draining / wait_until_idle / optional
after_runtime_shutdown protocol remains unchanged. Registry methods define
what those callbacks mean for MultiAgent. The admission registry waits for
active coordination calls; Team ownership waits for in-progress construction,
not for every retained Team to disappear. Live Team references are cleared
only after successful resource shutdown. Runtime acquires no Team/Handoff rules.
The shared callback protocol alone is not a reason to add a new logical Contract.

The default adapter shares registries by their existing class keys within each
Runtime. Concurrent adapters get the same registered instance. Lookup does not
register a participant, including after draining starts. Admission acquisition
continues to reject a stopped/failed Runtime; a retained ownership registry can
still be looked up, while its own construction gate rejects new work.

Team and Handoff capture their environment on construction. Existing objects do
not switch registry or cancellation destination when the provider changes.
The default adapter compares the captured Runtime with the current default to
preserve stale-owner rejection. Cancellation submission uses the captured
Runtime explicitly. The environment itself is neither persisted nor authority
for a durable execution. This is an internal composition extension, not a new
supported application plugin API.

Public Team/Handoff signatures, exception classes, durable IDs, record schemas,
CAS rules, parent/child atomic participation and recovery semantics are unchanged.
ReservedChildAdmission still validates domain reservations within the shared
persistence scope. It is distinct from the process-local AdmissionRegistry.
Engine lifecycle and Execution completion/cancellation rules are unchanged.

## Evidence and remaining scope

Standalone tests use both registries without loading Engine. Connection tests
exercise Team identity and store consistency, duplicate Handoff calls, release
on failure, stale-owner rejection, original-environment cancellation, callback
cleanup and real worker submission after default Runtime replacement. Existing
shutdown tests cover concurrent registration, construction during draining,
failed EventLoop closure, deadlines and finalization. Durable coordination and
recovery suites remain acceptance gates.

The dependency model adds M89/G63 for multi_agent/runtime_binding. AST guards
reject Runtime/Engine selection and private shutdown registration/lookup inside
MultiAgent domain files. Graph guards reject direct domain-to-Engine/binding
dependencies while retaining lower-level reverse-dependency restrictions.
Measured Ruby/RBS references remain visible; these are scoped rules, not proof
that the complete dependency graph is acyclic or every Contract is complete.

Remaining work includes Workflow connections and durable child outcomes,
MultiAgent's existing global/default persistence selection, broader semantic
dependency review, and live-service/additional persistence acceptance gates.
This unit completes the proposed C01 Runtime connection split, not all C01 work.
