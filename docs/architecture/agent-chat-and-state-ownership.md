# Agent Chat and explicit state ownership (R09, second slice)

## Purpose and clients

Agent::Base is the declaration and lifecycle facade used by application Agent
subclasses. It also supplies internal hooks to normal execution, follow-up LLM
calls and recovery. Those callers need a Chat built from the selected or saved
model settings and populated with an already materialized projection. They do
not ask the Chat constructor to make Context Policy decisions again.

Applications create Agents and explicitly add knowledge, clear context/history,
reset context or close an idle Agent through Base. These operations append
Journal records and advance an AgentRoot together. The existing live root is
authoritative; an operation must not silently reload a newer root and retry.

Refactor 42 extracted ToolBinding and documented existing declaration rules.
Refactor 43 separates the remaining Chat construction and explicit state writes
while keeping the Base facade and live-state publication boundary.

## Ownership and placement

| Owner | Responsibility |
|---|---|
| Base | Public declarations and lifecycle entry points, live-owner checks, selected class settings, operation-specific root changes, projection installation and publication of successful state writes. |
| RuntimeChatBuilder | RubyLLM Chat options and setters; provider-specific instruction cache representation. |
| StateWriter | Initial root/context/knowledge persistence and explicit idle-Agent Journal/root changes in one transaction. |
| ContextImporter / JournalRecord / AgentRoot | Existing history validation, record meanings and immutable root values. |
| ToolBinding / Orchestrator | Existing Tool decoration and invocation-specific subagent context. |
| ExecutionCoordinator and its workers | Existing execution-time writes and EventLoop-side publication, unchanged here. |

RuntimeChatBuilder and StateWriter live in agent/context_assembly, whose existing
collaborators already turn context inputs into runtime or durable records.
StateWriter is orchestration over ContextImporter, JournalRecord and AgentRoot;
it is not a low-level lifecycle primitive or a raw storage adapter. Placing it
in lifecycle would introduce lifecycle -> context_assembly and enlarge the
existing directory cycle. That placement was rejected during design validation.
No new directory, loader rule, mixin or namespace alias is needed.

There are two new internal collaborator classes, plus StateWriter's private
Update data value containing root and appended records. Neither collaborator
holds an Agent reference or invokes private Agent methods through send. The
mutation block passed to StateWriter is the existing operation-specific root
proposal, called at the same point inside the transaction.

## Chat construction and installation

Base#build_chat selects its default model/provider/temperature/token settings
only when model_config is falsey. An explicit empty Hash remains an explicit
config. RuntimeChatBuilder then builds options, creates RubyLLM.chat, applies
temperature, optionally applies max_output_tokens and returns the original
Chat, irrespective of setter return values. Zero remains a valid setting.

Base#apply_instructions keeps its signature and delegates the provider detail.
Only a truthy cache flag with provider.to_s == "anthropic" wraps instructions
in Anthropic::Content(cache: true). All other values pass through unchanged;
the with_instructions return value is retained.

Base#_apply_runtime_projection_to_chat remains a short orchestration hook. It
installs system instructions, prepares and installs each Tool in order, then
appends the original message objects to the existing Chat messages. Keeping the
hook retains application/test overrides of apply_instructions and Orchestrator's
prepare_tool_class(invocation:) cooperation. Moving it into a builder receiving
the entire Agent would merely introduce callbacks back into Base.

AgentInvocationSessionBuilder and InvocationRestorer keep using the same hooks.
Saved config is authoritative during recovery; current class declarations do
not overwrite it. A failure stops installation at that operation, propagates
the same error and does not install later Tools/messages. No new Chat cache,
provider-independent SPI, LLM call or Tool execution path is introduced.

## Initial persistence

Base resolves the Agent definition before calling StateWriter#create_root.
StateWriter constructs the initial root, then performs the existing sequence:

1. Create the root in the transaction.
2. Import/encode context records, followed by knowledge records, in order.
3. If records exist, append them at position zero, advance both revisions to
   one and save the root with expected_revision zero.
4. Return the resulting root after the transaction call returns successfully.

Empty initial input does not append or advance revisions. String coercion of
knowledge, metadata normalization, imported text/JSON handling and invalid-format
errors remain unchanged. Base's initialize_owned_state still assigns the root,
reads the committed Journal and freezes its local record array. Hydration and
definition compatibility checks remain unchanged in Base.

## Explicit mutation and publication

For add_knowledge and context/lifecycle changes, Base first checks live ownership
and captures agent_root. StateWriter takes that root, persistence and agent ID
explicitly. Each operation retains this transaction sequence:

1. Assert durable execution idleness.
2. Construct the content/state record and append with the captured Journal head.
3. Build the next root; a context mutation's proposal block runs after append.
4. Save with the captured expected Agent revision.
5. After the transaction call returns, return Update(root, appended records).

Base applies the returned Journal records before replacing @root. StateWriter
never publishes live state and never reloads the mutable root or Journal.
add_knowledge still returns self; clear/reset/close still return the new root.
close! increments Agent revision while preserving context revision. Context
changes preserve the old generation in the event and the existing revision
fallback rule in the resulting root.

Block, content, append, CAS and commit failures escape without publication.
Failures inside a supported transaction roll back its durable writes. An error
is not wrapped, retried or turned into a false successful return. The transaction
method's own return value is ignored as before.

This is not a stronger transaction or concurrency contract. If a backend commits
then reports an unknown outcome, or local Journal publication fails after a
successful commit, durable and live state can differ just as before. There is
no new F1 reconciliation for these manual operations. If an application encloses
an Agent mutation in an outer Persistence transaction, returning from the inner
scope is not proof of the outer commit; this refactor adds no deferred-publication
or outer-rollback coordination. Application-owned outer transactions need a
separate design decision, not an implicit guarantee from this extraction.

The public lifecycle checks, purge ownership protocol, admission, hydration,
execution commits, SQL and stored formats are unchanged. Relocated private
record-building helpers are not retained as an extension API. Retained Chat,
Tool and root-proposal hooks keep their names and signatures.

## Validation and completion rule

Thirty-seven additional behavioral examples run through Base against both the
unchanged Refactor 42 and this candidate. They cover saved/default/empty config,
provider options, setter and hook ordering, original objects/errors, import
formats, atomic rollback, idle checks, event/revision rules and publication.
The existing architecture guard now checks StateWriter as well as Base for
forbidden mutable-root/Journal reload and live-state publication paths.

Full core/integration/examples, real SQLite, public API/SPI, RBS, style, isolated
gem loading and independent package application are recorded in the release
evidence. New private helpers are distinguished from the unchanged public
contract and retained hook signatures. Static dependency analysis rejects new
cycle membership rather than merely checking unchanged edge counts.

Refactor 43 is applied and verified at core 5c4c0392; R09 is closed. Its Tool
binding and declaration rules were already verified in Refactor 42. Base remains
the public facade; keeping short orchestration methods there is intentional.
The DSL behavior itself remains unchanged. R10 is implemented in Refactor 44,
pending application verification. The published SVG is applied43-01. See the
[naming boundary](entry-action-and-team-wording.md) and the separate
[open Tool schema finding](tool-schema-recording-gap.md).
