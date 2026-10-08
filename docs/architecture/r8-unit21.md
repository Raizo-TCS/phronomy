# r8 unit21: Tool and Tracing settings ownership

This responsibility-only refactor is based on applied unit20, commit
`bda5da03da5a4da33041953cf0eebaa32de7bb81` (tree
`dc601f86825116b34ff294200815809ee9e0ea7a`). It addresses B10 from the
Contract review. It is not a new execution feature or a unit20 regression fix.

## Ownership

| Owner | Responsibility |
| --- | --- |
| C06 Tool | Own the default result-length value and the existing truncation rules |
| C15 Tracing | Own tracer access, the recording option and the existing observation/redaction rules |
| C05 Context | Obtain its default tracer through C15 at Assembly construction; honor explicit injection |
| Application composition | Select values and concrete tracers, expose the existing Configuration facade, bind lazy accessors |
| Neutral RuntimeSettings | Retain logger and execution resource sizes/time thresholds |

Tool::Settings contains one optional max_result_size value. Tracing::Settings
contains tracer and trace_pii. These private value containers have no settings
hierarchy, backend selection, notification service or execution resources.
Composition supplies them through lazy providers, following the existing Agent
and Workflow pattern. No Contract receives the whole application Configuration.
No new logical Contract is introduced merely because values are shared.

The public tool_result_max_size, tracer and trace_pii accessors keep their names,
defaults, writers and return values. Application choices remain application
choices. Tool truncation and Tracing redaction already belonged to their domains;
their algorithms are unchanged. Logger access remains neutral and is not moved
simply because Tracing also uses it for diagnostic messages.

This amends ADR-060's earlier grouping of tracer and recording options with
neutral runtime settings. The static graph treated that container as common;
its lack of reverse references did not prove that every field belonged there.

## Preserve lifecycle and read positions

- Binding providers does not evaluate global configuration or start Runtime.
- Tool reads its default at the existing result-processing site, after
  synchronous execution or successful asynchronous completion. An explicit
  class limit keeps priority and bypasses the default read. Nil and zero retain
  their existing meanings. Result transformations retain their order and count.
- Automatic tracing reads settings at span start and retains the same tracer
  and recording flag in its existing handle until finish. A configuration reset
  during execution does not transfer an open span to a different tracer.
- Observation keeps its existing reads before entering the application block;
  it does not adopt a new snapshot policy or re-read settings after the block.
- Context::Assembly keeps its constructor-time tracer. Explicit injection,
  including explicit nil, does not resolve the default provider.
- Configuration copies duplicate the value containers and preserve injected
  tracer/logger identities. Nested scopes, exception restoration and reset keep
  the previous behavior. A read resolves the current container without caching.

There is no change notification, polling, version counter, cache, live resource
resizing or new thread-local configuration behavior. This does not add a
guarantee of atomic reconfiguration across several independent reads.

## Regression boundaries

Public behavior tests run unchanged on unit20 and unit21. They cover late Tool
limits for sync/cooperative/offloaded/deferred operations, transformation order
and repetition, physical completion, reset, nested scopes and tracer identity.
Tracing checks cover both recording policies, redaction, errors and open spans;
Context checks cover constructor timing and explicit injection.

Separate ownership tests inject domain values without the application facade
or neutral settings. Isolated loading verifies provider laziness and prevents
loading a concrete backend or Runtime. RBS assigns the internal declarations to
their actual owners. AST gates extend the application-configuration prohibition
to Tool, Tracing and Context, reject domain fields in neutral RuntimeSettings,
and reject direct or literal-reflective reads through its old accessors.

These are targeted regression guards. They do not prove arbitrary dynamic Ruby
dependencies. Full suite, integration, existing privacy tests, examples offline
verification and Ruby/RBS architecture analysis remain package validation gates.
The complete source/tree and validation results are recorded in the package.

Unit19/20 Engine lifecycle and passive metrics behavior remain unchanged.
F01 durable Workflow children remain separate feature work. There is no stored
data migration, public operation change or source change to examples.
