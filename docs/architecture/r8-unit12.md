# r8 unit 12: C01 subagent operations use the C06 Tool contract

Contract placement follows ownership of meaning and invariants, not reuse.
This unit addresses B03: Orchestrator.subagent generated a subclass of the
concrete Tools::Agent implementation (I04). The generated class replaced Agent
creation and child coordination, but inherited Tool operation rules incidentally.

| Owner | Responsibility |
| --- | --- |
| MultiAgent / C01 | Define the subagent operation, child class, knowledge/context inheritance, child error policy and durable reconciliation |
| Agent / C04 | Public child invocation and recovery outcomes |
| Tool / C06 | Input schema, Tool error policy, result limits and completion-handle requirements |
| Execution / C13 | Nonblocking completion composition and physical completion propagation |
| Tools::Agent / I04 | Standalone concrete Agent Tool construction through from_agent |

Orchestrator remains an Agent::Base subclass: a coordinating Agent is a valid
C01-to-C04 relationship. Its generated subagent Tool now derives directly from
Tool::Base and explicitly declares cooperative execution and its input schema.
Generating this domain-owned operation belongs to C01; no runtime registry,
factory, new logical Contract or composition layer is needed for that operation.

Tool::Base has a private call_async_operation helper that validates inputs,
requires a completion handle, applies Tool error policy and limits successful
results. Its block supplies the domain operation. It does not create Agents,
select implementations, wait for completion or decide how many application
filters to run. Both the subagent operation and Tools::Agent use this helper.
The default Tool::Base#call_async path and synchronous-call delegation are
unchanged, including the unit 9 result-transformation behavior.

ExecutionRehydrationRequiredError remains an Agent-domain outcome. Tools::Agent
and the C01 operation retain their private pass-through hooks; C06 does not
reference this error or interpret recovery. Generic errors retain their original
backtrace when wrapped; ToolError and CancellationError remain unchanged.
Suppression logging uses C06's existing RuntimeSettings logger capability.

An ordinary asynchronous subagent call still checks cancellation before schema
validation, starts the child without occupying a waiting offload worker, maps
its output and applies Tool policy. The subagent on_error option continues to
control child failure (raise or skip); it is distinct from Tool on_error policy.

An admitted durable child follows the existing reconciliation path directly.
It is reconciled even with a cancelled parent token; unknown outcomes and
recovery requirements are not hidden. This path retains its existing validation,
result and cancellation behavior, without adding the ordinary-call truncation
or error-suppression pipeline. Agent-owned configured result transformations
still wrap either path in the configured order, including repeated filters.
Parent/child IDs, reservations, stores, persistence schemas and recovery rules
are unchanged. Logical settlement does not falsely imply physical completion.

## Evidence and remaining scope

Non-Agent Tool tests cover asynchronous validation/coercion, errors, result
limits, cancellation and separate physical completion. Subagent tests cover
operation without Tools::Agent, ordinary and admitted-child cancellation,
recovery error identity and repeated transformations after truncation. Existing
pool-starvation, knowledge inheritance, durable coordination/restart and result
transformation tests remain acceptance gates.

The AST gate rejects concrete Tools references in C01 domain files and
Agent recovery interpretation in C06. The Ruby/RBS graph gate rejects C01
domain-to-tools implementation dependencies. Existing lower-level and Engine
binding rules remain intact. These are targeted regression checks, not proof
of all logical Contract dependencies or global acyclicity.

B03 is addressed in this candidate. C02 Workflow execution connections, its
separately scoped durable child guarantees, and broader Recovery responsibility
review remain. No completed status is asserted for all of C01/C02/C04.
