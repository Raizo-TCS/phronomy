# ADR-020: Canonical Workflow Instance Identity

## Status

Accepted.

## Date

2026-08-23

## Context

Phronomy currently uses `thread_id` for the logical/durable identity of a
Workflow. The value does not identify a Ruby or operating-system Thread. It
identifies one logical Workflow instance across invoke, halt, resume, live
signal routing, and `Persistence#workflow_states`.

At the same time, `FSMSession#id` identifies one concrete Runtime FSM
incarnation. One logical Workflow may use more than one FSMSession over its
lifetime. Reusing the generic name `thread_id` for the Workflow domain identity
therefore obscures the boundary between durable identity and Runtime routing.

ADR-014 records the earlier `thread_id` terminology. The architecture
reconciliation program resolved this terminology under CG-01 / ACS-13. This ADR
makes that narrow identity decision repository authority without pulling the
remaining Workflow admission-owner, terminal durability, fencing, or recovery
changes into the same implementation slice.

## Decision

### 1. `workflow_instance_id` is the canonical Workflow identity

The canonical logical Workflow identity is:

```text
workflow_instance_id
  = one logical Workflow instance
  = the logical Persistence#workflow_states key when the Workflow is durable
```

`thread_id` is not retained as a Workflow architecture term.

`workflow_instance_id` is framework-owned WorkflowContext metadata, not an
application state field. Applications must not declare
`WorkflowContext.field(:workflow_instance_id)`; Phronomy rejects that declaration
to prevent application state from shadowing or persisting the canonical Workflow
identity. Applications already using that field name must rename their
application field when adopting this identity contract.

### 2. The migration is a clean break

Public and extension surfaces change directly:

```text
WorkflowContext#thread_id
  -> WorkflowContext#workflow_instance_id

Workflow#signal(thread_id:)
  -> Workflow#signal(workflow_instance_id:)

Workflow invocation config[:thread_id]
  -> config[:workflow_instance_id]

WorkflowStateRepository load/save/delete parameter meaning
  thread_id
  -> workflow_instance_id
```

No deprecated Workflow `thread_id` alias is provided.

The removed Workflow config key is rejected explicitly rather than ignored.
Silently ignoring it could allocate a fresh identity and branch durable Workflow
history, which is more dangerous than a visible migration error.

### 3. Durable identifier values do not change

This decision renames the semantic parameter, not the identifier value.

```text
old durable key value: "order-123"
new durable key value: "order-123"
```

Existing durable values remain the identity of the same logical Workflow
instance. A backend does not need to generate replacement identifiers.

The Persistence Backend SPI uses `workflow_instance_id` as the logical parameter
name and meaning. A backend may keep an existing physical database column or key
name internally; this ADR does not require a physical schema rename solely for
terminology.

### 4. Workflow identity is not inherited from generic InvocationContext identity

Workflow invocation does not implicitly copy `InvocationContext#thread_id` into
its domain identity.

If an application needs durable Workflow identity, it supplies
`workflow_instance_id` explicitly through the Workflow API/configuration.

This decision does not remove Agent/correlation `thread_id` surfaces from
`InvocationContext` or Agent APIs. Their generic-identity reconciliation is a
separate Compatibility Gate.

### 5. FSMSession identity remains separate

`FSMSession#id` / `fsm_session_id` identifies one concrete Runtime FSM
incarnation and is not the Workflow domain identity.

CG-01 does not rename the shared Runtime-internal `graph_thread_id` bridge used
by `FSMSession`. WorkflowRunner may continue to pass the canonical
`workflow_instance_id` value through that existing generic bridge so that a
replacement WorkflowContext receives the same durable identity before halt or
finish. WorkflowContext maps that Runtime-internal metadata onto
`workflow_instance_id`; this does not create a public `thread_id` accessor,
Workflow config key, signal keyword, or deprecated Workflow API alias. Renaming
the shared FSMSession graph-metadata protocol belongs to the separate Runtime
identity reconciliation.

```text
Workflow W1
  workflow_instance_id = W1

  FSMSession S1
    id = S1
      -> halt

  FSMSession S2
    id = S2
      -> resume / finish
```

No `workflow_execution_id` is introduced by this decision.

### 6. This ADR supersedes only ADR-014 Workflow identity terminology

ADR-014 remains historical and current authority for the portions not superseded
here. Wherever ADR-014 calls the logical/durable Workflow identity `thread_id`,
this ADR replaces that terminology with `workflow_instance_id`.

The current admission-owner representation and terminal-save ordering are not
made normative by this ADR merely because the current implementation still
contains them.

## Consequences

### Positive

- The Workflow domain identity says what it identifies.
- Durable Workflow identity and Runtime FSMSession identity are no longer named
  as if they were the same kind of session/thread concept.
- Persistence backend implementations receive an unambiguous logical SPI
  parameter name.
- Existing durable identifier values can continue unchanged.
- A removed config key cannot silently create a new durable identity.

### Trade-offs

- This is a pre-1.0 breaking API/SPI change.
- Applications using `config[:thread_id]`, `WorkflowContext#thread_id`, or
  `Workflow#signal(thread_id:)` must migrate.
- Custom Persistence backends should update method parameter names and
  documentation even when their physical database schema remains unchanged.

## Explicit non-goals

CG-01 does not decide or implement:

- replacement of Workflow admission ownership by an opaque owner token/handle;
- durable terminal/halt save as an FSM barrier before logical terminalization;
- EventLoop/FSMSession ownership redesign beyond identity nomenclature;
- cross-process ownership, leases, or fencing;
- process-loss recovery or rehydration;
- Agent/InvocationContext generic identity removal;
- a new `workflow_execution_id`.

Those concerns remain separate architecture-reconciliation work and must not be
inferred from this identity-only decision.
