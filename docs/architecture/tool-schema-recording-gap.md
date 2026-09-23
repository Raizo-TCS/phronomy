# Historical finding: Tool parameter schema is absent from saved definitions

## Observed mismatch

During Refactor 44 verification, Ruby 3.3.6 with RubyLLM 1.16.0 reproduced the
following on both applied Refactor 43 and the Refactor 44 candidate:

1. The prepared Tool exposes its actual argument schema through `params_schema`.
2. `Agent::ToolDefinitionSet.build` asks for `parameters_schema`, which this Tool
   does not respond to, and stores an empty Hash for that field.
3. `select_definitions` compares the stored definitions exactly, but a change
   from optional string `summary` to required integer `summary` is accepted
   because neither definition contains its actual argument schema.

The LLM request still includes the actual schema. The missing information is in
Phronomy's recorded definition and therefore in the comparison boundary. Tool
names and top-level descriptions are still compared; this finding does not mean
all Tool identity checks are absent. The source of ToolDefinitionSet is unchanged
by R10, and no claim is made about untested RubyLLM versions.

## Consequence

Recovery/context materialization cannot reject that incompatible argument change
through the saved definition comparison. The R10 parameter-description change
also does not cause a mismatch on this tested version. Passing old/new recovery
checks must not be presented as evidence that parameter compatibility is guarded.

## Required follow-up

This is an open correctness issue, separate from the R10 naming cleanup.
A follow-up should obtain the schema actually used by the supported adapter,
record it in canonical form and compare it during context selection/recovery.
It must also specify how to treat old saved definitions whose schema is `{}`.
Blindly switching the reader would make new definitions conflict with historical
manifests; blindly ignoring mismatches would erase the intended guard.

Acceptance requires meaningful parameter-change rejection, matching-schema
continuation, explicit treatment of missing historical schema, adapter-version
coverage and old/new recovery validation. Until that work is accepted, retain
this issue in the current work list. Refactor 44 does not silently migrate records
or change the general Tool comparison contract.

## Refactor 45 resolution candidate

[The RubyLLM 2 migration](rubyllm-2-token-ownership.md) removes the empty fallback,
records the actual schema/provider options and rejects incompatible definitions.
It explicitly rejects historical empty schemas when materializing in-flight
manifests. Matching current definitions continue normally. The original observation
above is retained as evidence; it is not a description of the new implementation.
Application verification of Refactor 45 remains pending.
