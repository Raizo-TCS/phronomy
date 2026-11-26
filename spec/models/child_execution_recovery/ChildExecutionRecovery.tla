----------------------- MODULE ChildExecutionRecovery -----------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Mode, Outcome, TerminalKind, ParentInitial, Fault, FreshCaller,
          ExplicitRetry, Readable, PhysicalEvidence, BackendSettles,
          ParentCaller, ParentPolicyAllowsImport, CompletionAvailable, StableRead, ObserveClients, Bug
VARIABLES save, durable, worker, owner, parent, clients
vars == <<save, durable, worker, owner, parent, clients>>
Observers == 1..2
ActiveObservers == IF ObserveClients THEN Observers ELSE {}
Terminal == Mode = "terminal"
FaultEnabled(name) == Fault = "all" \/ Fault = name \/
  (Fault = "refused_proof_change" /\ name \in {"refused", "proof_change"})
Fields == {"root", "execution", "journal", "extension", "cancellation"}
Before == [root |-> "active", execution |-> [revision |-> 1, correlation |-> 1],
  journal |-> "before", extension |-> "none", cancellation |-> FALSE]
After == [root |-> IF Terminal THEN "idle" ELSE "prepared",
  execution |-> [revision |-> 2, correlation |-> 1], journal |-> "after",
  extension |-> "none", cancellation |-> FALSE]
Change(row, field) ==
  IF field = "execution" THEN [row EXCEPT !.execution.correlation = 2]
  ELSE IF field = "cancellation" THEN [row EXCEPT !.cancellation = TRUE]
  ELSE [row EXCEPT ![field] = "different"]
Matches(row, expected) ==
  IF Bug \in Fields THEN [row EXCEPT ![Bug] = expected[Bug]] = expected
  ELSE IF Bug = "retention_is_authority" THEN durable.parentHold
  ELSE row = expected
Classify(row) ==
  IF ~Readable \/ ~durable.settled THEN "unknown"
  ELSE IF Matches(row, After) THEN "post"
  ELSE IF Matches(row, Before) THEN "pre"
  ELSE "unknown"
ExactOwner == owner.generation = 1
PhysicalKnown == save.physical /\ worker.physical

Init ==
 /\ save = [quiet |-> FALSE, physical |-> FALSE, handle |-> PhysicalEvidence]
 /\ durable = [footprint |-> IF Outcome = "post" THEN After ELSE Before,
       settled |-> FALSE, parentHold |-> TRUE,
       holdVersion |-> 1,
       parentRevision |-> 1, parentSlot |-> 1, parentCancelled |-> FALSE,
       changed |-> FALSE, terminalFact |-> TerminalKind,
       terminalSaved |-> Terminal /\ Outcome = "post", retryWrites |-> 0]
 /\ worker = [phase |-> "idle", physical |-> TRUE, count |-> 0,
       kind |-> "read", result |-> "unknown", snapshot |-> Before,
       completeProof |-> FALSE, staleWrite |-> FALSE]
 /\ owner = [held |-> TRUE, localAdmission |-> TRUE, wanted |-> FALSE,
       request |-> "read", known |-> "unknown", fresh |-> FALSE,
       generation |-> 1, applied |-> FALSE, applications |-> 0,
       validApplication |-> TRUE, physicalAtApplication |-> TRUE,
       preparationRuns |-> 1, businessRuns |-> 1,
       refused |-> FALSE, admitted |-> FALSE, admissionUnknown |-> FALSE,
       admissions |-> 0, effects |-> 0, localCancelled |-> FALSE,
       grantValid |-> TRUE, continuation |-> "pending", pairUnloaded |-> FALSE]
 /\ parent = [authorized |-> ParentInitial # "failed", generation |-> 1,
       imported |-> ParentInitial = "imported",
       importCount |-> IF ParentInitial = "imported" THEN 1 ELSE 0,
       importValid |-> TRUE, freshResult |-> "unused"]
 /\ clients = [originalInvocation |-> "failed", originalPublic |-> "pending",
       originalPublicFinal |-> "none",
       originalParent |-> IF ParentInitial = "imported" THEN "complete" ELSE ParentInitial,
       parentFailed |-> ParentInitial = "failed", externalObservation |-> "pending",
       receiptCorrelation |-> [i \in Observers |-> 0],
       receipt |-> [i \in Observers |-> "unused"],
       closed |-> [i \in Observers |-> FALSE]]

SaveReturns ==
 /\ ~save.quiet
 /\ save' = [save EXCEPT !.quiet = TRUE]
 /\ UNCHANGED <<durable, worker, owner, parent, clients>>
ObservePhysical ==
 /\ save.quiet /\ ~save.physical
 /\ save.handle \/ Bug = "return_is_proof"
 /\ save' = [save EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<durable, worker, owner, parent, clients>>
SettleBackend ==
 /\ BackendSettles /\ ~durable.settled
 /\ durable' = [durable EXCEPT !.settled = TRUE]
 /\ UNCHANGED <<save, worker, owner, parent, clients>>

RequestRead ==
 /\ FreshCaller /\ owner.held /\ ~owner.wanted /\ ~owner.fresh
 /\ worker.phase = "idle" /\ worker.count < 3
 /\ owner.known # "pre" \/ ~ExplicitRetry
 /\ owner' = [owner EXCEPT !.wanted = TRUE, !.request = "read"]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
RequestRetry ==
 /\ FreshCaller /\ ExplicitRetry /\ owner.held /\ ~owner.wanted
 /\ owner.known = "pre" /\ worker.phase = "idle" /\ worker.count < 3
 /\ owner' = [owner EXCEPT !.wanted = TRUE, !.request = "retry"]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
BeginAttempt ==
 /\ owner.held /\ owner.wanted /\ ExactOwner /\ worker.phase = "idle"
 /\ save.physical \/ Bug = "ignore_physical"
 /\ durable.settled
 /\ Bug # "require_original_holds" \/ durable.holdVersion = 1
 /\ worker' = [worker EXCEPT !.phase = "running", !.physical = FALSE,
       !.count = @ + 1, !.kind = owner.request, !.result = "unknown",
       !.completeProof = FALSE]
 /\ owner' = [owner EXCEPT !.fresh = FALSE]
 /\ UNCHANGED <<save, durable, parent, clients>>
RecordAttempt ==
 /\ worker.phase = "running"
 /\ LET fact == IF Bug = "cached_pre_write" /\ worker.kind = "retry"
                   THEN "pre" ELSE Classify(durable.footprint)
        write == worker.kind = "retry" /\ fact = "pre"
        result == IF write THEN "post" ELSE fact
        snapshot == IF write THEN After ELSE durable.footprint
    IN /\ worker' = [worker EXCEPT !.phase = "recorded",
           !.result = IF write /\ FaultEnabled("lost_retry_reply")
                       THEN "unknown" ELSE result,
           !.snapshot = snapshot,
           !.completeProof = (result = "post" /\ snapshot = After) \/
                            (result = "pre" /\ snapshot = Before),
           !.staleWrite = @ \/ (write /\ durable.footprint # Before)]
       /\ durable' = [durable EXCEPT
           !.footprint = snapshot, !.retryWrites = @ + IF write THEN 1 ELSE 0,
           !.terminalSaved = @ \/ (Terminal /\ write),
           !.terminalFact = IF write /\ Bug = "rewrite_terminal_fact"
             THEN IF TerminalKind = "succeeded" THEN "cancelled" ELSE "succeeded" ELSE @]
       /\ owner' = [owner EXCEPT
           !.preparationRuns = @ + IF write /\ Bug = "rebuild_preparation" THEN 1 ELSE 0,
           !.businessRuns = @ + IF write /\ Bug = "replay_business" THEN 1 ELSE 0]
 /\ UNCHANGED <<save, parent, clients>>
AttemptPhysicallyCompletes ==
 /\ worker.phase = "recorded" /\ ~worker.physical
 /\ worker' = [worker EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<save, durable, owner, parent, clients>>
AcceptProof ==
 /\ worker.phase = "recorded" /\ worker.physical /\ ExactOwner
 /\ owner' = [owner EXCEPT
       !.known = IF @ = "post" THEN @ ELSE worker.result,
       !.fresh = worker.result = "post", !.wanted = FALSE]
 /\ worker' = [worker EXCEPT !.phase = "idle"]
 /\ UNCHANGED <<save, durable, parent, clients>>

(* The five-field child footprint excludes retentions and the parent's changing
   revision. StableRead bounds the read-to-owner use; it is not a storage fence. *)
MayChangeFootprint == ~StableRead \/ worker.phase = "running" \/
  (worker.phase = "idle" /\ ~owner.fresh) \/
  (owner.refused /\ worker.count = 1)
ChangeFootprint(field) ==
 /\ FaultEnabled("proof_change") /\ field \in Fields
 /\ ~durable.changed /\ owner.held /\ MayChangeFootprint
 /\ durable' = [durable EXCEPT !.footprint = Change(@, field), !.changed = TRUE]
 /\ UNCHANGED <<save, worker, owner, parent, clients>>
ChangeHoldSet ==
 /\ FaultEnabled("hold_change") /\ durable.holdVersion = 1
 /\ durable' = [durable EXCEPT !.holdVersion = 2]
 /\ UNCHANGED <<save, worker, owner, parent, clients>>
AdvanceParent ==
 /\ FaultEnabled("parent_progress") /\ durable.parentRevision = 1
 /\ durable' = [durable EXCEPT !.parentRevision = 2]
 /\ UNCHANGED <<save, worker, owner, parent, clients>>
ChangeParentSlot ==
 /\ FaultEnabled("parent_slot") /\ durable.parentSlot = 1 /\ ~parent.imported
 /\ durable' = [durable EXCEPT !.parentSlot = 2]
 /\ UNCHANGED <<save, worker, owner, parent, clients>>
CancelParent ==
 /\ FaultEnabled("parent_cancel") /\ ~durable.parentCancelled
 /\ durable' = [durable EXCEPT !.parentCancelled = TRUE,
       !.parentHold = IF Bug = "cancel_drops_hold" THEN FALSE ELSE @]
 /\ UNCHANGED <<save, worker, owner, parent, clients>>
CancelLocalChild ==
 /\ FaultEnabled("local_cancel") /\ ~owner.localCancelled
 /\ owner' = [owner EXCEPT !.localCancelled = TRUE]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
ReplaceOwner ==
 /\ FaultEnabled("owner_change") /\ owner.generation = 1
 /\ owner' = [owner EXCEPT !.generation = 2]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
ApplyChild ==
 /\ owner.held /\ owner.known = "post" /\ owner.fresh /\ ~owner.applied
 /\ ExactOwner \/ Bug = "stale_owner"
 /\ PhysicalKnown \/ Bug = "ignore_physical"
 /\ Bug # "freeze_parent_revision" \/ durable.parentRevision = 1
 /\ owner' = [owner EXCEPT !.applied = TRUE, !.applications = @ + 1,
       !.validApplication = ExactOwner /\ worker.completeProof /\
                            worker.snapshot = After /\ durable.footprint = After,
       !.physicalAtApplication = PhysicalKnown]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
RefuseDispatch ==
 /\ ~Terminal /\ owner.applied /\ owner.fresh /\ ~owner.refused
 /\ FaultEnabled("refused") /\ ~owner.admitted /\ ~owner.admissionUnknown
 /\ owner' = [owner EXCEPT !.refused = TRUE,
       !.fresh = Bug = "cached_post_grant", !.wanted = FALSE]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
CanContinue ==
 /\ ~Terminal /\ owner.held /\ owner.applied /\ owner.fresh /\ ExactOwner
 /\ PhysicalKnown /\ ~owner.admitted /\ ~owner.admissionUnknown
 /\ ~FaultEnabled("refused") \/ owner.refused
ContinueDispatch ==
 /\ CanContinue
 /\ owner' = [owner EXCEPT
       !.grantValid = worker.completeProof /\ worker.snapshot = After /\
                      durable.footprint = After,
       !.admitted = owner.localCancelled \/ ~FaultEnabled("unknown_admission"),
       !.admissionUnknown = ~owner.localCancelled /\ FaultEnabled("unknown_admission"),
       !.admissions = @ + IF owner.localCancelled /\ Bug # "ignore_cancel" THEN 0 ELSE 1,
       !.continuation = IF owner.localCancelled THEN "cancelled" ELSE "resumed"]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
ExternalEffect ==
 /\ ~Terminal /\ owner.admissions = 1 /\ owner.effects = 0
 /\ owner' = [owner EXCEPT !.effects = 1]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
MatchingCompletion ==
 /\ CompletionAvailable /\ owner.admissionUnknown /\ owner.effects = 1 /\ ExactOwner
 /\ owner' = [owner EXCEPT !.admissionUnknown = FALSE, !.admitted = TRUE]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
ReleaseChild ==
 /\ owner.held /\ owner.applied /\ ExactOwner
 /\ PhysicalKnown \/ Bug = "ignore_physical"
 /\ Terminal \/ owner.admitted
 /\ owner' = [owner EXCEPT !.held = FALSE,
       !.localAdmission = ~Terminal,
       !.continuation = IF Terminal THEN "terminal" ELSE @]
 /\ durable' = [durable EXCEPT !.parentHold =
       IF Terminal /\ Bug = "release_drops_hold" THEN FALSE ELSE @]
 /\ UNCHANGED <<save, worker, parent, clients>>

(* A parent's existing pending importer can see a durable terminal fact before
   the child recovers locally. A failed observation needs a new explicit caller. *)
FailParentObservation ==
 /\ (FaultEnabled("parent_error") \/ clients.originalPublic = "failed" \/
      (~ParentPolicyAllowsImport /\ clients.originalPublic = "terminal"))
 /\ clients.originalParent = "pending"
 /\ clients' = [clients EXCEPT !.originalParent = "failed", !.parentFailed = TRUE]
 /\ parent' = [parent EXCEPT !.authorized = FALSE]
 /\ UNCHANGED <<save, durable, worker, owner>>
ResumeParent ==
 /\ Terminal /\ ParentCaller /\ ParentPolicyAllowsImport
 /\ clients.originalParent = "failed"
 /\ ~parent.authorized /\ ~parent.imported /\ durable.parentSlot = 1
 /\ durable.parentHold /\ parent.generation = 1
 /\ parent' = [parent EXCEPT !.authorized = TRUE, !.freshResult = "pending"]
 /\ UNCHANGED <<save, durable, worker, owner, clients>>
ImportChild ==
 /\ Terminal /\ ParentPolicyAllowsImport /\ parent.authorized /\ ~parent.imported /\ durable.settled
 /\ durable.terminalSaved /\ durable.footprint.execution.correlation = 1
 /\ durable.parentHold /\ parent.generation = 1
 /\ clients.originalPublic = "terminal" \/ parent.freshResult = "pending"
 /\ durable.parentSlot = 1 \/ Bug = "wrong_parent_import"
 /\ parent' = [parent EXCEPT !.imported = TRUE, !.importCount = @ + 1,
       !.importValid = durable.parentSlot = 1,
       !.freshResult = IF @ = "pending" THEN "complete" ELSE @]
 /\ UNCHANGED durable
 /\ clients' = [clients EXCEPT !.originalParent =
       IF @ = "pending" THEN "complete" ELSE @]
 /\ UNCHANGED <<save, worker, owner>>
ReleaseImportedHistory ==
 /\ Terminal /\ parent.imported /\ durable.parentHold
 /\ durable' = [durable EXCEPT !.parentHold = FALSE, !.holdVersion = 2]
 /\ UNCHANGED <<save, worker, owner, parent, clients>>
UnloadPair ==
 /\ Terminal /\ parent.imported /\ ~owner.pairUnloaded
 /\ (~owner.localAdmission /\ ~owner.held /\ PhysicalKnown) \/ Bug = "parent_import_unloads_pair"
 /\ owner' = [owner EXCEPT !.pairUnloaded = TRUE]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
RequestReceipt(i) ==
 /\ FreshCaller /\ clients.receipt[i] = "unused"
 /\ clients' = [clients EXCEPT !.receipt[i] = "pending"]
 /\ UNCHANGED <<save, durable, worker, owner, parent>>
DeliverReceipt(i) ==
 /\ clients.receipt[i] = "pending" /\ owner.known \in {"pre", "post"}
 /\ clients' = [clients EXCEPT !.receipt[i] = "complete",
       !.receiptCorrelation[i] = IF Terminal /\ owner.known = "post" THEN
         IF Bug = "drop_receipt_correlation" THEN 2 ELSE 1 ELSE 0]
 /\ UNCHANGED <<save, durable, worker, owner, parent>>
CloseOriginalPublicTerminal ==
 /\ Terminal /\ durable.settled /\ durable.terminalSaved /\ Readable
 /\ durable.footprint.execution.correlation = 1 /\ clients.originalPublic = "pending"
 /\ clients' = [clients EXCEPT !.originalPublic = "terminal", !.originalPublicFinal = "terminal"]
 /\ UNCHANGED <<save, durable, worker, owner, parent>>
CloseOriginalPublicError ==
 /\ clients.originalPublic = "pending"
 /\ ~Terminal \/ Outcome = "pre" \/ ~Readable \/ FaultEnabled("public_error")
 /\ clients' = [clients EXCEPT !.originalPublic = "failed", !.originalPublicFinal = "failed"]
 /\ UNCHANGED <<save, durable, worker, owner, parent>>
ObserveDurableExecution ==
 /\ Terminal /\ durable.settled /\ durable.terminalSaved
 /\ durable.footprint.execution.correlation = 1
 /\ clients.externalObservation = "pending"
 /\ clients' = [clients EXCEPT !.externalObservation = "complete"]
 /\ owner' = [owner EXCEPT !.held = IF Bug = "observation_releases_owner" THEN FALSE ELSE @]
 /\ UNCHANGED <<save, durable, worker, parent>>
CancelReceipt(i) ==
 /\ FaultEnabled("observer_cancel") /\ clients.receipt[i] = "pending"
 /\ clients' = [clients EXCEPT !.receipt[i] = "cancelled", !.closed[i] = TRUE]
 /\ owner' = [owner EXCEPT !.held = IF Bug = "observer_drops_custody" THEN FALSE ELSE @]
 /\ UNCHANGED <<save, durable, worker, parent>>
ReplayUnknown ==
 /\ Bug = "replay_unknown" /\ owner.admissionUnknown /\ owner.admissions = 1
 /\ owner' = [owner EXCEPT !.admissions = 2]
 /\ UNCHANGED <<save, durable, worker, parent, clients>>
DuplicateImport ==
 /\ Bug = "duplicate_import" /\ parent.imported /\ parent.importCount = 1
 /\ parent' = [parent EXCEPT !.importCount = 2]
 /\ UNCHANGED <<save, durable, worker, owner, clients>>
ReopenOriginal ==
 /\ Bug = "reopen_original" /\ ~owner.held /\ clients.originalInvocation = "failed"
 /\ clients' = [clients EXCEPT !.originalInvocation = "complete"]
 /\ UNCHANGED <<save, durable, worker, owner, parent>>

Next == SaveReturns \/ ObservePhysical \/ SettleBackend \/ RequestRead \/ RequestRetry
 \/ BeginAttempt \/ RecordAttempt \/ AttemptPhysicallyCompletes \/ AcceptProof
 \/ ChangeHoldSet \/ AdvanceParent \/ ChangeParentSlot \/ CancelParent
 \/ CancelLocalChild \/ ReplaceOwner \/ ApplyChild \/ RefuseDispatch \/ ContinueDispatch
 \/ ExternalEffect \/ MatchingCompletion \/ ReleaseChild \/ FailParentObservation
 \/ ResumeParent \/ ImportChild \/ ReleaseImportedHistory \/ UnloadPair \/ CloseOriginalPublicTerminal
 \/ CloseOriginalPublicError \/ ObserveDurableExecution \/ ReplayUnknown \/ DuplicateImport \/ ReopenOriginal
 \/ (\E field \in Fields : ChangeFootprint(field))
 \/ (\E i \in ActiveObservers : RequestReceipt(i) \/ DeliverReceipt(i) \/ CancelReceipt(i))
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(SaveReturns) /\ WF_vars(ObservePhysical)
 /\ WF_vars(SettleBackend) /\ WF_vars(RequestRead) /\ WF_vars(RequestRetry)
 /\ WF_vars(BeginAttempt) /\ WF_vars(RecordAttempt) /\ WF_vars(AttemptPhysicallyCompletes)
 /\ WF_vars(AcceptProof) /\ WF_vars(ApplyChild) /\ WF_vars(RefuseDispatch)
 /\ WF_vars(ContinueDispatch) /\ WF_vars(ExternalEffect) /\ WF_vars(MatchingCompletion)
 /\ WF_vars(ReleaseChild) /\ WF_vars(CloseOriginalPublicTerminal)
 /\ WF_vars(CloseOriginalPublicError) /\ WF_vars(FailParentObservation) /\ WF_vars(ResumeParent) /\ WF_vars(ImportChild) /\ WF_vars(UnloadPair)

TypeOK ==
 /\ save.quiet \in BOOLEAN /\ save.physical \in BOOLEAN /\ save.handle \in BOOLEAN
 /\ durable.settled \in BOOLEAN /\ durable.parentHold \in BOOLEAN
 /\ durable.terminalSaved \in BOOLEAN
 /\ durable.holdVersion \in 1..2 /\ durable.parentRevision \in 1..2 /\ durable.parentSlot \in 1..2
 /\ durable.terminalFact \in {"succeeded", "failed", "cancelled"} /\ durable.retryWrites \in 0..2
 /\ worker.phase \in {"idle", "running", "recorded"} /\ worker.count \in 0..3
 /\ worker.kind \in {"read", "retry"} /\ worker.result \in {"unknown", "pre", "post"}
 /\ owner.known \in {"unknown", "pre", "post"} /\ owner.generation \in 1..2
 /\ owner.applications \in 0..1 /\ owner.preparationRuns \in 1..2 /\ owner.businessRuns \in 1..2
 /\ owner.admissions \in 0..2 /\ owner.effects \in 0..1
 /\ owner.continuation \in {"pending", "resumed", "cancelled", "terminal"}
 /\ parent.importCount \in 0..2 /\ parent.freshResult \in {"unused", "pending", "complete"}
 /\ clients.originalInvocation \in {"failed", "complete"}
 /\ clients.originalPublic \in {"pending", "failed", "terminal"}
 /\ clients.originalPublicFinal \in {"none", "failed", "terminal"}
 /\ clients.originalParent \in {"pending", "failed", "complete"}
 /\ \A i \in Observers : clients.receipt[i] \in {"unused", "pending", "cancelled", "complete"}
CompleteChildProof == owner.applied => owner.validApplication
PhysicalBeforeApplication == owner.applied => owner.physicalAtApplication
PhysicalKnowledge == save.physical => save.handle
FreshProofBeforeGrant == owner.grantValid
NoStaleProposalWrite == ~worker.staleWrite
NoPreparationReplay == owner.preparationRuns = 1
NoBusinessReplay == owner.businessRuns = 1
SingleDispatch == owner.admissions <= 1
CustodyUntilApplication == ~owner.held => owner.applied /\ PhysicalKnown
UnknownAdmissionRetained == owner.admissionUnknown => owner.held
ParentResultCustody == Terminal /\ ~owner.localAdmission /\ ~parent.imported => durable.parentHold
HoldUntilImport == Terminal /\ ~parent.imported => durable.parentHold
ExactParentImport == parent.importValid
SingleImport == parent.importCount <= 1
PairUnloadAfterChildCustody == owner.pairUnloaded => ~owner.localAdmission /\ ~owner.held /\ PhysicalKnown
ClosedOriginalsStayClosed == clients.originalInvocation = "failed" /\
 (clients.parentFailed => clients.originalParent = "failed") /\
 (clients.originalPublicFinal # "none" => clients.originalPublic = clients.originalPublicFinal)
ClosedObserversStayClosed == \A i \in Observers : clients.closed[i] => clients.receipt[i] = "cancelled"
TerminalFactPreserved == durable.terminalFact = TerminalKind
ReceiptCorrelationPreserved == \A i \in Observers : clients.receiptCorrelation[i] \in {0, 1}
CancelledContinuationNoDispatch == owner.continuation = "cancelled" => owner.admissions = 0
EventuallyChildResolved == <> (~owner.held)
EventuallyImported == <> parent.imported
EventuallyPairUnloaded == <> owner.pairUnloaded
NoPreRetainedWitness == ~(owner.known = "pre" /\ owner.held /\ owner.admissions = 0)
NoImportedPendingChildWitness == ~(parent.imported /\ owner.held /\ ~save.physical)
NoReleasedProtectedResultWitness == ~(Terminal /\ ~owner.localAdmission /\ durable.parentHold /\ ~parent.imported)
NoRecoveredFailedParentWitness == ~(~owner.held /\ parent.imported /\ clients.originalParent = "failed" /\ parent.freshResult = "complete")
NoIndependentObserversWitness == ~(clients.receipt[1] = "cancelled" /\ clients.receipt[2] = "complete")
NoParentProgressWitness == ~(~owner.held /\ durable.parentRevision = 2)
NoChangedHoldsRecoveryWitness == ~(~owner.held /\ durable.holdVersion = 2)
NoUnknownAdmissionWitness == ~(owner.admissionUnknown /\ owner.effects = 1 /\ owner.held)
NoPolicyRetainedResultWitness == ~(~ParentPolicyAllowsImport /\ ~owner.localAdmission /\
  ~parent.imported /\ durable.parentHold /\ clients.originalParent = "failed")
NoSuccessfulOriginalPendingCustodyWitness == ~(clients.originalPublic = "terminal" /\ owner.held)
NoDurableObservationPendingCustodyWitness == ~(clients.externalObservation = "complete" /\ owner.held)
NoLocalCancelWitness == ~(~owner.held /\ owner.continuation = "cancelled" /\ owner.admissions = 0)
=============================================================================
