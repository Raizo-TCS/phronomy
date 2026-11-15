# Legacy-format cleanup

Phronomy 0.34.0 keeps current saved facts and removes specific historical read
fallbacks and conversion facilities. It does not rewrite stores or introduce a
new record version. Retiring the conversion facilities is an intentional removal
of migration support, not a claim that another public API replaces them.

For example, a newly authorized Tool operation continues to store its validated
arguments, including type coercion and meaningful null values. Its reader no
longer reconstructs those arguments from an older raw-input field.

## Handoff conversation groups

Handoff uses the conversation group recorded by the current Context assembly.
The historical selection-unit ID and kind no longer supply grouping or category
information. Segments without a current group still use the ordinary per-segment
fallback; reserved internal metadata is still removed from transferred content.

For example, current Tool-call and Tool-result segments share
`context_policy_conversation_group_id` and remain together when a Handoff policy
selects that exchange. A saved `selection_unit_id` is no longer an alternative
source for that relationship. The Manifest codec remains strict about its
supported version and required fields.

## Authorized Tool arguments

Agent Store reads the exact validated argument snapshot for an authorized
operation. The raw request remains a separate fact and is not a substitute when
the validated snapshot is absent.

For example, raw `{"count":"2","optional":null}` may validate as
`{"count":2,"optional":null}`. Authorization matching must use the integer and
retain the explicit null. An authorized record missing `validated_arguments`
fails instead of falling back to `arguments` and dropping null values.

Provider-response recovery can temporarily record an `authorized` placeholder
without that snapshot. The normal `framework_calls` continuation validates its
Tool invocation and saves the prepared snapshot before an operation consumer
reads it. Directly projecting the intermediate placeholder is rejected; its
status alone is not proof that its arguments have been validated. A resumed
`framework_tools` continuation instead uses its previously saved dispatch
snapshot.

## Retired conversion support

The pre-S3 `Persistence::Migration::InitialFormatMigration` API and the
GeneratorVerifier Result JSON converter are removed, along with the former
command's usage instructions. There is no compatibility alias or replacement
conversion command. Ordinary Agent and Workflow persistence, current Manifest
decoding and GeneratorVerifier Result validation remain in their owning domains.

For example, `GeneratorVerifier::Result.from_h` still requires `failure` even
when its value is null. It does not add missing fields to historical JSON.
The separate `PersistenceComposition::Unit4Migration` snapshot conversion is
retained and was not an implementation of either removed conversion facility.
