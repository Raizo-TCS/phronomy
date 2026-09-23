# Removal of the internal parallel Chat path

This change belongs to the incremental architecture refactor following 0.26.0.
It does not publish a new gem version.

## Application changes

Remove assignments to `Phronomy.configuration.parallel_tool_execution`, including
assignments inside `Phronomy.configure`. Both the reader and writer are removed;
there is no compatibility accessor or replacement switch. The former setting
selected a Chat subclass but did not gate concurrency in the Agent-owned Tool
execution path. A previous value of `false` did not guarantee serial execution.

`Phronomy::MultiAgent::ParallelToolChat` and its file are removed. Do not require
the old file or instantiate that private class. No `Agent::ParallelToolChat`
replacement or alias is introduced. Applications that need Agent-owned Tool
approval, cancellation and execution tracking should enter through the Agent
invoke/stream APIs. Direct RubyLLM chat use is outside that Agent lifecycle.

## Retained behavior

Both complete and streaming calls use ordinary `RubyLLM::Chat`. Before the first
Tool body runs, the existing RubyLLM callback lets Agent capture every Tool call
in the complete assistant message. Agent manages Tool authorization, approval,
dispatch, cancellation and result collection under ADR-010 and ADR-024.

On success, every result is associated with its original call ID and recorded
in request order. All results are included in the next Provider request, after
the batch completes. Runtime capacity and each Tool's execution mode still
determine how work can overlap. This change does not introduce a serial Tool
mode or a partial-result Provider continuation.

The old direct-Chat fallback and its RubyLLM-specific callback/Halt behavior are
removed with the private class. They are not a second supported Agent execution
API. Agent-level event callbacks keep their existing contract.

## Existing stored records

New standard model-config records omit `parallel_tool_execution`. Existing
ContentStore records and manifest hashes are not rewritten. An existing record
may still contain that field; materialization preserves its bytes and Agent's
Chat builder ignores it, just as it ignores other unused model-config fields.
There is no manifest version change or compatibility branch that reinstates the
removed Chat class.

The regression suite checks materialization and Chat construction for stored
records containing both historical boolean values. Existing recovery tests
continue to cover the supported recovery contracts; this change does not add
execution-resumption or external-effect guarantees.
