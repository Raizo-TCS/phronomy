# R8 unit 9: preserve application-defined Tool result transformations

## Ownership

The application owns which transformations run, their order and their
multiplicity. Agent's ToolBinding captures and composes its configured filters.
C06 Tool owns the operation/decorator mechanism that executes that composition.
C13 Execution owns completion adaptation, failure/cancellation propagation and
physical-completion tracking. Shared use is not the reason for C06 ownership.

There is no universal "one filter per public invocation" policy. Each configured
stage must retain its position and multiplicity. Registering the same filter
twice or nesting result decorators remains meaningful application composition.

## Defect

In unit 7 and unit 8 a custom call_async delegating with super reached Base's
default async bridge, which invoked the decorated synchronous call. A second
decoration then transformed the custom async completion. One configured stage
therefore ran twice. If the custom implementation additionally mapped the result,
the first transformation also ran on an intermediate value rather than the
custom operation's final result.

## Internal delegation

Operation.with_result_transform records the exact synchronous wrapper method
only when that decorator also installs an async completion wrapper. Base's
call_async obtains a bound synchronous delegate from Operation. That delegate
skips the leading framework wrappers whose async counterparts already own their
stages. ToolExecutor receives the callable explicitly and invokes it inline or
inside the submitted worker, on the original Tool instance.

Selection stops at application methods and sync-only decorator stages. Exact
method matching avoids bypassing a later application replacement, including a
singleton call override. No Thread/Fiber local flag, per-instance busy flag,
cloning, value tagging, equality check or filter-identity deduplication is used.

## Application calls remain application calls

Only Base's standard async-to-sync bridge is internal delegation. A custom
implementation that explicitly calls the public call method invokes that
method's configured transformations. Its async completion can then have its own
transformation. The framework does not guess whether the application intended
that explicit call to be raw execution.

For example, with a bracket transform:

| Composition | Result for x |
| --- | --- |
| One stage, custom call_async delegates using super | [x] |
| Two registrations of the bracket transform | [[x]] |
| Custom maps super's raw value to custom:x, then one stage | [custom:x] |
| Custom explicitly calls the decorated public call and prefixes custom: | [custom:[x]] |

Applications wanting Base's normal execution as an implementation step should
use super. Applications can also call their configured filters explicitly; those
calls are never deduplicated. A custom override inserted between decorators is
an application boundary, not a wrapper the framework may silently bypass.

## Preserved completion contract

Custom completions still use AsyncOperation.map. Original failures retain their
identity, source cancellation remains cancellation, and physical completion waits
for both source work and active transformations. Cancelling a mapped result still
does not implicitly cancel its source. Default cooperative/offloaded dispatch,
the owning submitter, public keyword arguments, effective names, receiver state,
and schema/authorization rules remain intact.

## Scope

This is a core-only correction. Public signatures and stored schemas are unchanged.
It does not complete the remaining C01/C02 connections, all C04 composition,
the source dependency cycles, or the broader acceptance gates.
