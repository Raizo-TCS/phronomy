# ADR-061: Domain Persistence failure contracts

- Status: Accepted
- Date: 2026-09-26
- Amends: [032-storage-backend-composition](032-storage-backend-composition.md) and [058-neutral-storage-primitives](058-neutral-storage-primitives.md), only for the exception surface exposed above raw Storage.

## Context

Agent execution, ownership, Handoff, Recovery, Team coordination and Workflow
interpret durable failures, but previously referenced raw Storage exception
classes even when they did not perform raw storage operations. A domain state
contradiction and a physical compare-and-swap rejection had the same owner.
Moving or aliasing those classes would keep backend and domain contracts coupled.

## Decision

Define independent public errors in `persistence/contract/`, under the existing
`Phronomy::Persistence` namespace: Error, ConflictError, StateConflictError,
NotFoundError, SerializationError and UnsupportedBackendError. Error inherits
Phronomy::Error. StateConflictError inherits Persistence::ConflictError; the other
four categories inherit Persistence::Error. No class inherits a Storage error,
and no compatibility alias is introduced. The contract depends only on Common.

The selected upper domain consumers raise StateConflictError for their own
ownership/revision/state contradictions. Backend CAS conflicts, including
repository precondition conflicts, expose Persistence::ConflictError. Existing
conflict retry/catch sites also accept StateConflictError by inheritance.

An internal `Persistence::StorageBoundary` maps exactly four Storage categories
(ConflictError, NotFoundError, SerializationError, UnsupportedBackendError) to
the corresponding Persistence category. It preserves message and backtrace and
sets the original exception as `cause`. Mapping happens at domain repository
exits and Persistence construction/transaction exits. Existing repository-local
constraint interpretation runs first: only the matching active-owner unique
constraint or exact NoRows condition becomes AgentBusyError. Other raw conflict
subclasses map to Persistence::ConflictError with their metadata in `cause`.

Domain repositories continue to own codecs and record validation. Decode checks
remain inside the physical atomic block, so a malformed write response still
rolls back before translation. The translator creates no transaction or task.
The same boundary covers root and transaction repository views, watermark checks,
and persisted manifest reading. A private ContentRepository adapts the existing
StoredContents primitive methods for the upper failure contract; the independent
ContentStore backend retains its content identity and integrity semantics.

Unknown exceptions, Storage::TransactionError, ContentStore::IntegrityError,
AgentBusyError and already translated Persistence errors pass through unchanged.
Persistence::Error is a base type, not a blanket known-not-committed classifier.
Each existing caller retains its exact category set, including intentional
three-category/four-category differences and ArgumentError/ConfigurationError.
A lost commit acknowledgement must not become a known rejection or trigger a
new retry. F0/F1/F4 recovery and X0 limitations are unchanged.

## Loading and ownership

Contracts can be loaded without Storage, Engine, Agent or a driver. Ordinary
framework loading explicitly installs the canonical Persistence service before
Zeitwerk setup, so an earlier contract load cannot suppress service methods or
change class identity. This does not construct a backend or start a Runtime.
The API class is still defined in `persistence/api/persistence.rb`. Namespace
reopenings in helpers are not its declaration owner for dependency analysis.

## Public migration and preservation

Calls through Persistence now expose Persistence errors rather than Storage
errors. This is an intentional public exception contract change; applications
must migrate relevant rescue clauses. Raw backend/driver code keeps Storage
errors. See the [migration guide](../migrations/persistence-failure-contracts.md).

Existing public method/RBS declarations remain; six error classes are added.
SPI 2, tables, record envelopes, revisions, content IDs and all eight repository
transaction semantics remain unchanged. Stored error class names are diagnostic
data: new failures may name Persistence errors, while old saved names remain
readable without rewriting or constantizing them.

## Verification and diagram

Tests inject real backend failures through all eight repository accessors and
check cause/trace, no double translation, unknown-error identity, commit-response
loss, nested savepoints, post-write validation rollback and AgentBusyError.
Existing domain recovery, admission, conformance and integration suites remain
required. Raw Storage isolation tests continue to reject domain/Engine loading.

Ruby + RBS boundary validation rejects raw Storage references from the eight
reviewed upper directories and rejects non-Common reachability from Persistence
Contracts. It does not whitelist the new dependencies. G55 shows the translation
boundary and G56 the independent domain failure contracts in the existing banded
layout. All measured edges remain in evidence and the matrix; presentation-only
incoming-arrow filters do not change boundary results.
