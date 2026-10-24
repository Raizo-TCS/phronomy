# V2 revision 2 - Changes

Updated: 2026-09-06 / Status: Accepted

## Accepted decisions reflected in this revision

| Item | Change in this revision |
|---|---|
| RC-01 Result access | Add contracts for reading status/results by exact execution ID and discovering candidates from the owner if execution is interrupted before the caller receives the ID |
| RC-02 Unknown persistence outcomes | Distinguish confirmed absence, read failure, CAS conflict, and unknown commit outcome; reconcile using the same reserved identity |
| RC-03 Wiring compatibility | Specify minimum checks for definition id/version, slot, graph, and Persistence boundary, and give precedence to committed facts |
| RC-04 Cancellation | Distinguish ending observation/shutdown from semantic cancellation; specify handling by child state, races, and rediscovery after restart |
| RC-05 Guarantee wording | Use consistent wording: reuse committed outcomes, recover with the same identity, and resolve uncertain external outcomes through existing Recovery |

The corresponding normative statements have been incorporated into ADR-029/030/031, the implementation design, the responsibility boundary review, and the README.
Detailed contracts and validation conditions are collected in RECOVERY_CONTRACT_CLARIFICATIONS.md and referenced across the documents.
The pre-approval Proposed status has been changed to Accepted. This does not request renewed approval of the new functionality.

## Correction of implementation status

Earlier implementation counts and successful static checks in the handoff document remain reports from the previous session.
They are not evidence that implementation was revalidated in this continuation. Only the design documents and handoff document are currently available;
the old overlay/apply.py/APPLY.sh/VERIFY.sh have not been recovered. The resumption procedure has also been updated to begin by recovering the actual files.

## Checks performed for this revision

- Check consistency of approval status, baseline, and cross-references in the affected documents.
- Correct obsolete statements that implementation was stopped pending approval and guarantee wording that could imply exactly-once external effects.
- Check the mapping of RC-01 through RC-05 to ADRs, implementation design, and validation conditions.
- Verify the ZIP layout, SHA256SUMS for all documents, and external SHA256 values for the ZIP and handoff document.

No code changes or RSpec runs were performed in the target repository.
Unverified API or exception names were not invented; mapping the requirements to the baseline was made mandatory before implementation.
