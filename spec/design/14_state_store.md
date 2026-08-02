# Phronomy — State Store

## 1. Overview

`StateStore` persists serializable `WorkflowContext` snapshots by Workflow
`thread_id`. It does not persist Runtime objects, FSMSession instances, running
Tasks, callbacks, or provider operations.

A store may be configured globally, per Workflow definition, or per invocation:

```ruby
Phronomy.configure do |config|
  config.state_store = MyStateStore.new
end

workflow = Phronomy::Workflow.define(MyContext, state_store: another_store) do
  # ...
end

workflow.invoke(
  input,
  config: {
    thread_id: "workflow-42",
    state_store: request_specific_store
  }
)
```

The effective precedence is:

1. `config[:state_store]`
2. store supplied to `Workflow.define`
3. `Phronomy.configuration.state_store`

When no store is configured, Workflow execution remains in memory and no
snapshot is written. A new execution without an explicit `config[:thread_id]`
also remains unpersisted, even when a default store exists; the generated UUID is
an execution identifier, not an implicit durable-state key.

## 2. Interface

`Phronomy::StateStore::Base` defines:

| Method | Contract |
|---|---|
| `load(thread_id)` | Return a snapshot Hash or `nil` |
| `save(thread_id, snapshot)` | Replace the snapshot for the thread |
| `delete(thread_id)` | Delete the snapshot if present |

A snapshot has the following shape:

```ruby
{
  fields: workflow_context.to_h,
  phase: workflow_context.phase.to_s
}
```

`fields` are application data. `phase` records the phase reached when the
snapshot was written.

## 3. Common execution preparation

`Workflow#invoke`, `Workflow#invoke_async`, and `Workflow#stream` use the same
`WorkflowRunner` preparation path:

```text
select effective StateStore
→ determine thread_id and recursion_limit
→ load snapshot when an existing thread_id was supplied
→ merge stored fields with the current input
→ build WorkflowContext
→ register one FSMSession with the Runtime EventLoop
```

Current input overrides values loaded from the snapshot:

```ruby
initial_fields = stored_fields.merge(input)
```

Changing from `invoke` to `stream` therefore changes only observation behavior;
it does not change initial context or persistence semantics.

## 4. Common finalization

A Workflow result is finalized after its FSMSession reports `:finished` or
`:halted`:

```text
FSMSession terminal event
→ WorkflowRunner finalizer
→ StateStore#save
→ public completion Task settles
```

Consequently:

- synchronous `invoke` raises a save failure on the caller thread;
- `invoke_async` fails its returned Task;
- synchronous `stream` raises the failure on the caller thread.

The same snapshot format is used for all three APIs.

## 5. Resume and live events

`resume` and `send_event` continue from a halted `WorkflowContext` supplied by
the caller. They do not rebuild a new context from stored fields before firing
the event. Their resulting terminal/halted context is persisted by the common
finalizer.

`Workflow#signal` targets an already-live FSMSession. It neither loads nor saves
a snapshot by itself. Persistence occurs when that session subsequently reaches
a terminal or halted boundary, or when an application-defined checkpoint is
implemented separately.

## 6. What is not durable

The following are deliberately not stored:

- `Phronomy::Task` instances;
- callback/listener closures;
- Agent or Tool provider operations;
- EventLoop queue contents;
- FSMSession objects;
- application-owned Task registries.

If a process stops while external work is running, Phronomy does not reconstruct
that work from the Workflow snapshot. Applications that require durable
orchestration need an explicit recovery/idempotency design.

Serializable correlation values needed after restart may be stored as ordinary
WorkflowContext fields:

```ruby
field :generation_request_id
field :provider_request_id
```

## 7. Stored phase is not automatic process recovery

Loading a snapshot for a new `invoke` restores `fields`; it does not automatically
recreate an FSMSession at the stored phase. Continuing a known halted context is
performed through `resume` or `send_event`.

Automatic recovery from an arbitrary stored phase would require additional
policy for entry replay, external side effects, operation reconstruction, and
idempotency. That behavior is outside the current StateStore contract.
