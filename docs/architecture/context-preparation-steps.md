# Context preparation steps

## Role and scope

ContextAssembler prepares the immutable semantic input supplied to Application
ContextPolicy and later validates and stores its decision as an LLMInputManifest.
InitialPreparation and DispatchPreparation run preparation outside their commit
transactions, recheck durable state, then call finalize in the commit transaction.
The public boundary and those callers already have separate responsibilities.

R07 addresses a narrower readability problem inside prepare_initial and
prepare_followup: orchestration was mixed with individual item IDs, provenance
and metadata, and record filtering plus Hook/Handoff merging were duplicated.
The original proposal calls for private extraction before adding collaborators.
Refactor 40 follows that limit: one production file changes; no class is added.

## Reading order and responsibilities

| Private operation | Responsibility |
|---|---|
| initial_instruction_items | Choose the initial Agent instruction and optional Handoff responsibility, in order. |
| agent_instruction_item | Build the required system instruction with its stable ID, estimate and Agent provenance. |
| handoff_instruction_item | Build the required user responsibility with its ID, estimate and Handoff origin. |
| retained_instruction_items | Read only retained base instructions from the previous Manifest, using the existing compatibility predicate and converter. |
| resolve_record_candidates | Filter working records by eligibility/current generation and resolve them with Journal candidates and caller-provided exclusions. |
| merge_context_candidates | Add Hook candidates, then Handoff candidates, using the existing creation, sorting and storage operations. |
| current_input_item | Build the initial required ask argument after all candidates, including ID, sequence, provenance and metadata. |

Public preparation keeps model/Tool settings, source loading and the sequence of
these operations visible. Record collection and candidate augmentation stay as
two steps: follow-up computes its next call sequence after record resolution,
exactly as before. No new options object, pipeline DSL, mutable preparation state
or cross-feature factory is introduced. Helpers remain private to the assembler.

## Preserved contracts

- Initial instructions come from the Agent configuration plus optional Handoff
  responsibility. Follow-up instructions come from the retained base Manifest.
  Current Hook instructions are rebuilt; previous Hook/Policy-generated items
  do not become permanent base instructions. Legacy origin handling is unchanged.
- Working records must remain context candidates in the active transcript
  generation. Initial preparation excludes the current input record; follow-up
  includes eligible working records without that exclusion.
- Record candidates are resolved before Hook and then Handoff augmentation. The
  current-input sequence follows all candidates, including non-conversation ones.
  IDs, source fields, trust metadata, estimates, required flags, ordering, frozen
  values and delivery modes retain their existing values.
- Initial input content is loaded before instruction-item construction and
  candidate resolution. Initial instruction callbacks and patch normalization
  retain their order. Hook content writes still precede Handoff type validation;
  moving that validation earlier would be a behavior change and is not included.
- Preparation is not side-effect-free: Hook/Handoff content may be stored before
  Policy succeeds. This extraction neither adds rollback nor suppresses existing
  exceptions. Missing-input, reserved-metadata, resolver and Policy failures keep
  their ordering; collaborator exception objects propagate unchanged.
- Application Policy executes once during prepare; finalize does not invoke it.
  Finalization, its validation/encoding/store helpers, assembly policy version 8,
  schemas, public signatures and transaction-owning callers are unchanged.

The new helpers use the same constructor field evaluation and call ordering.
They do not cache or deduplicate reads, normalize values earlier, or move work
across the prepare/finalize boundary merely to shorten the source.

## Verification and trade-off

Ten behavior examples cover initial item provenance/immutability, generation and
exclusion rules, content-write order, absent instructions/Handoff, follow-up
retention and current hooks, the prepare/finalize boundary and failure precedence.
The same examples pass on Refactor 39. Four independent baseline/candidate
scenario pairs compare complete Policy input, Prepared values, Manifest bytes and
content references, plus preparation-time content read/write order. The pairs
cover initial and follow-up calls with/without base instructions and Handoff.

Full core/integration suites, common examples and real SQLite, stable/beta API
and Storage SPI snapshots, RBS, style, annotations and isolated gem checks are
also run. Live PostgreSQL, live LLM, remote CI and performance are not exercised
for this candidate; prior CI is not evidence for the candidate's core.

prepare_initial is 103 -> 55 lines and prepare_followup 57 -> 47. The whole file
is 625 -> 672 lines because seven named private methods and explicit arguments
add structure. This is a readability and duplicated-procedure improvement, not a
net line-count reduction or a directory-cycle change. The methods' names give
readers a place to choose whether they need the detailed representation.

R07 was independently verified after application at core b3dfbc5a, tree
dcd9d1bf8efb1b488f9c2b3b1c4e99bdeda6096c. All six files and the full tree matched;
core/integration/examples/SQLite/API/type/gem and four paired scenarios passed.
R07 is complete. The published diagram is applied40-01. R08/D08 now has a Refactor
41 candidate, with R09 and R10 remaining afterward. Their behavior and naming
decisions are not part of Context preparation extraction.
