------------------- MODULE InitialPreparationRecovery -------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Boundary, Save, Readable, RestoreReads, Caller, ExplicitRetry,
          SettleWorkers, Delivery, Submission, ParentCancellation,
          PreparationSucceeds, StableAuthority, Drift, Bug

VARIABLES owner, durable, work, clients, metrics, authority, reads
vars == <<owner, durable, work, clients, metrics, authority, reads>>
Stages == {"admission", "activation", "failure"}
Observers == 1..2

Init ==
 /\ owner = [stage |-> Boundary, phase |-> "uncertain", held |-> TRUE,
      controlsHeld |-> TRUE, parentCancelled |-> FALSE, fact |-> "unknown", grant |-> FALSE,
      factStage |-> Boundary, originalToken |-> 1, token |-> 1,
      preparationStarted |-> Boundary # "admission", consumed |-> FALSE,
      originalError |-> "preparation_error", terminalError |-> "none"]
 /\ durable = [stage |-> Boundary, state |-> Save, writes |-> 0]
 /\ work = [state |-> "idle", kind |-> "read", stage |-> Boundary,
      originalQuiet |-> FALSE, quiet |-> TRUE, result |-> "unknown",
      resultStage |-> Boundary, grant |-> FALSE, cancelled |-> FALSE, refused |-> FALSE, admitted |-> 0]
 /\ clients = [original |-> "pending", status |-> [i \in Observers |-> "unused"],
      cancelled |-> {}]
 /\ metrics = [preparations |-> IF Boundary = "admission" THEN 0 ELSE 1,
      installations |-> 0, providerCalls |-> 0, proposalRebuilds |-> 0,
      participantReplays |-> 0, safeWrites |-> TRUE, exactAdoptions |-> TRUE,
      validContinuation |-> TRUE, controlledContinuation |-> TRUE,
      physicalCustody |-> TRUE, retainedCustody |-> TRUE,
      validSubmission |-> TRUE, validFailure |-> TRUE]
 /\ authority = [owner |-> 1, store |-> 1, reservation |-> 1,
      freshGuard |-> TRUE, capturedDomain |-> TRUE, changed |-> FALSE]
 /\ reads = Readable

ExactIdentity == authority.owner = 1 /\ authority.store = 1 /\
  authority.reservation = 1 /\ owner.token = owner.originalToken
IdentityGrant == Bug = "wrong_identity" \/ ExactIdentity
FullAuthority == ExactIdentity /\ authority.freshGuard /\ authority.capturedDomain
ProofGrant == IdentityGrant /\ authority.freshGuard /\
  (Bug = "partial_authority" \/ authority.capturedDomain)
(* The complete domain proof is not reread by the later EventLoop owner gate.
   Stability spans the proof-to-continuation gap below. *)
LocalCancelled == owner.controlsHeld /\ owner.parentCancelled
CanStopAfterProof == LocalCancelled /\ (work.cancelled \/ work.grant)
OwnerContinuationGrant == IdentityGrant
WriteGrant == IF owner.stage = "failure" THEN IdentityGrant ELSE ProofGrant /\ ~LocalCancelled
ExactWriteAuthority == IF owner.stage = "failure" THEN ExactIdentity ELSE FullAuthority /\ ~owner.parentCancelled
Proof == IF ~reads \/ ~IdentityGrant THEN "unknown"
         ELSE IF durable.state = "divergent" THEN
           IF Bug = "partial_footprint" THEN "post" ELSE "unknown"
         ELSE durable.state

OriginalFails ==
 /\ clients.original = "pending"
 /\ clients' = [clients EXCEPT !.original = "failed"]
 /\ owner' = IF Bug = "close_controls" THEN [owner EXCEPT !.controlsHeld = FALSE] ELSE owner
 /\ UNCHANGED <<durable, work, metrics, authority, reads>>

OriginalCompletes ==
 /\ SettleWorkers /\ ~work.originalQuiet
 /\ work' = [work EXCEPT !.originalQuiet = TRUE]
 /\ UNCHANGED <<owner, durable, clients, metrics, authority, reads>>

RestoreRead ==
 /\ RestoreReads /\ ~reads
 /\ reads' = TRUE
 /\ UNCHANGED <<owner, durable, work, clients, metrics, authority>>

CancelParent ==
 /\ ParentCancellation /\ clients.original = "failed" /\ owner.held
 /\ owner.phase \notin {"installed", "terminal", "unadmitted"} /\ ~owner.parentCancelled
 /\ owner' = [owner EXCEPT !.parentCancelled = TRUE]
 /\ UNCHANGED <<durable, work, clients, metrics, authority, reads>>

BeginAttempt ==
 /\ Caller /\ clients.original = "failed" /\ owner.held
 /\ owner.phase = "uncertain" /\ work.state = "idle"
 /\ ~(owner.stage = "admission" /\ owner.fact = "pre" /\ work.cancelled)
 /\ work.originalQuiet \/ Bug = "ignore_physical"
 /\ LET refused == Submission = "refused" /\ ~work.refused
    IN /\ work' = [work EXCEPT
         !.state = IF refused THEN "idle" ELSE "running",
         !.quiet = refused, !.stage = owner.stage,
         !.kind = IF owner.fact = "pre" /\ ExplicitRetry THEN "retry" ELSE "read",
         !.refused = @ \/ refused,
         !.admitted = IF refused THEN 0 ELSE 1]
       /\ clients' = [clients EXCEPT !.status = [i \in Observers |->
           IF clients.status[i] = "unused" THEN "pending" ELSE clients.status[i]]]
 /\ UNCHANGED <<owner, durable, metrics, authority, reads>>

UnknownIsNotRefusal ==
 /\ Submission = "unknown" /\ work.state = "running"
 /\ Bug = "unknown_as_refusal" /\ work.admitted = 1
 /\ work' = [work EXCEPT !.admitted = 2]
 /\ metrics' = [metrics EXCEPT !.validSubmission = FALSE]
 /\ UNCHANGED <<owner, durable, clients, authority, reads>>

RecordAttempt ==
 /\ work.state = "running"
 /\ LET fact == IF Bug = "cached_pre" /\ owner.fact = "pre" THEN "pre" ELSE Proof
        write == work.kind = "retry" /\ fact = "pre" /\
          (Bug = "cached_pre" \/ WriteGrant)
        result == IF write THEN "post" ELSE fact
    IN /\ durable' = [durable EXCEPT
         !.state = IF write THEN "post" ELSE @,
         !.writes = IF write THEN 1 ELSE @]
       /\ work' = [work EXCEPT !.state = "recorded", !.result = result,
            !.resultStage = IF Bug = "wrong_stage" THEN "stale" ELSE work.stage,
            !.grant = ProofGrant, !.cancelled = LocalCancelled]
       /\ metrics' = [metrics EXCEPT
            !.safeWrites = @ /\ (~write \/ (durable.state = "pre" /\ ExactWriteAuthority /\ work.originalQuiet)),
            !.proposalRebuilds = @ + IF write /\ Bug = "rebuild_proposal" THEN 1 ELSE 0,
            !.participantReplays = @ + IF write /\ Bug = "replay_participant" THEN 1 ELSE 0]
 /\ UNCHANGED <<owner, clients, authority, reads>>

WorkerCompletes ==
 /\ SettleWorkers /\ work.state = "recorded" /\ ~work.quiet
 /\ owner.phase # "preparing"
 /\ owner.stage # "admission" \/ work.result # "post" \/ (~work.grant /\ ~CanStopAfterProof)
 /\ owner.stage # "activation" \/ (work.result # "post" \/ ~CanStopAfterProof)
 /\ owner.stage # "activation" \/ work.result # "pre" \/ ~work.cancelled
 /\ work' = [work EXCEPT !.quiet = TRUE]
 /\ UNCHANGED <<owner, durable, clients, metrics, authority, reads>>

DeliverAttempt ==
 /\ Delivery /\ work.state = "recorded" /\ work.quiet
 /\ work.resultStage = owner.stage \/ Bug = "wrong_stage"
 /\ owner' = [owner EXCEPT !.fact = work.result, !.factStage = work.resultStage, !.grant = work.grant,
      !.phase = IF work.result = "post" THEN "confirmed" ELSE "uncertain"]
 /\ work' = [work EXCEPT !.state = "idle"]
 /\ clients' = [clients EXCEPT
      !.status = [i \in Observers |-> IF clients.status[i] = "pending" THEN "complete" ELSE clients.status[i]],
      !.original = IF Bug = "reopen_original" THEN "complete" ELSE @]
 /\ UNCHANGED <<durable, metrics, authority, reads>>

(* First-time preparation belongs to the same recovery worker that read the
   admission proof. Its own physical completion comes after these callbacks. *)
BeginPreparation ==
 /\ work.state = "recorded" /\ work.result = "post" /\ work.grant /\ ~LocalCancelled
 /\ owner.phase = "uncertain" /\ owner.stage = "admission"
 /\ work.resultStage = owner.stage \/ Bug = "wrong_stage"
 /\ ~owner.preparationStarted \/ Bug = "replay_preparation"
 /\ OwnerContinuationGrant /\ (work.originalQuiet \/ Bug = "ignore_physical")
 /\ LET cancel == LocalCancelled
    IN /\ owner' = [owner EXCEPT
         !.phase = IF cancel THEN "uncertain" ELSE "preparing",
         !.stage = IF cancel THEN "failure" ELSE @,
         !.factStage = IF cancel THEN "failure" ELSE work.resultStage,
         !.fact = "post", !.grant = work.grant,
         !.preparationStarted = TRUE, !.consumed = TRUE,
         !.terminalError = IF cancel THEN "cancelled" ELSE @]
       /\ durable' = IF cancel THEN [durable EXCEPT !.stage = "failure", !.state = "post"] ELSE durable
       /\ work' = IF cancel THEN [work EXCEPT !.resultStage = "failure"] ELSE work
       /\ metrics' = [metrics EXCEPT
         !.preparations = @ + IF cancel THEN 0 ELSE 1,
         !.exactAdoptions = @ /\ (work.resultStage = owner.stage /\ durable.stage = owner.stage /\ durable.state = "post"),
         !.validContinuation = @ /\ FullAuthority,
         !.controlledContinuation = @ /\ (cancel \/ ~owner.parentCancelled),
         !.physicalCustody = @ /\ work.originalQuiet]
 /\ UNCHANGED <<clients, authority, reads>>

CompletePreparation ==
 /\ owner.phase = "preparing"
 /\ LET stage == IF PreparationSucceeds /\ ~LocalCancelled THEN "activation" ELSE "failure"
    IN /\ owner' = [owner EXCEPT !.stage = stage, !.factStage = stage,
         !.phase = "uncertain", !.fact = "post",
         !.terminalError = IF LocalCancelled THEN "cancelled" ELSE
           IF PreparationSucceeds THEN "none" ELSE owner.originalError]
       /\ durable' = [durable EXCEPT !.stage = stage, !.state = "post"]
       /\ work' = [work EXCEPT !.resultStage = stage]
 /\ UNCHANGED <<clients, metrics, authority, reads>>

(* Cancellation observed inside the worker saves one terminal proposal. If it
   arrives only at EventLoop application, custody is retained for a fresh call. *)
StopAfterProof ==
 /\ work.state = "recorded" /\ ~work.quiet /\ work.result = "post"
 /\ owner.stage \in {"admission", "activation"} /\ CanStopAfterProof
 /\ owner' = [owner EXCEPT !.stage = "failure", !.factStage = "failure",
      !.phase = "uncertain", !.fact = "post", !.terminalError = "cancelled"]
 /\ durable' = [durable EXCEPT !.stage = "failure", !.state = "post"]
 /\ work' = [work EXCEPT !.resultStage = "failure"]
 /\ UNCHANGED <<clients, metrics, authority, reads>>

StopBeforeActivation ==
 /\ work.state = "recorded" /\ ~work.quiet /\ work.result = "pre"
 /\ owner.stage = "activation" /\ work.cancelled
 /\ owner' = [owner EXCEPT !.stage = "failure", !.factStage = "failure",
      !.phase = "uncertain", !.fact = "post", !.terminalError = "cancelled"]
 /\ durable' = [durable EXCEPT !.stage = "failure", !.state = "post"]
 /\ work' = [work EXCEPT !.resultStage = "failure", !.result = "post"]
 /\ UNCHANGED <<clients, metrics, authority, reads>>

StopWithoutAdmission ==
 /\ owner.stage = "admission" /\ owner.phase = "uncertain" /\ owner.fact = "pre"
 /\ work.state = "idle" /\ work.cancelled /\ work.originalQuiet /\ work.quiet
 /\ IdentityGrant
 /\ owner' = [owner EXCEPT !.phase = "unadmitted", !.terminalError = "cancelled", !.consumed = TRUE]
 /\ metrics' = [metrics EXCEPT !.exactAdoptions = @ /\ durable.state = "pre",
      !.validContinuation = @ /\ ExactIdentity]
 /\ UNCHANGED <<durable, work, clients, authority, reads>>

AdoptActivation ==
 /\ owner.phase = "confirmed" /\ owner.stage = "activation"
 /\ owner.grant /\ OwnerContinuationGrant /\ (work.originalQuiet \/ Bug = "ignore_physical")
 /\ LET cancel == LocalCancelled
    IN /\ owner' = [owner EXCEPT
         !.phase = IF cancel THEN "uncertain" ELSE "installed",
         !.grant = IF cancel THEN FALSE ELSE @, !.consumed = TRUE]
       /\ metrics' = [metrics EXCEPT
         !.installations = @ + IF cancel THEN 0 ELSE 1,
         !.providerCalls = @ + IF cancel THEN 0 ELSE 1,
         !.exactAdoptions = @ /\ (owner.factStage = owner.stage /\ durable.stage = owner.stage /\ durable.state = "post"),
         !.validContinuation = @ /\ (cancel \/ FullAuthority),
         !.controlledContinuation = @ /\ (cancel \/ ~owner.parentCancelled),
         !.physicalCustody = @ /\ work.originalQuiet /\ work.quiet]
 /\ UNCHANGED <<durable, work, clients, authority, reads>>

AdoptFailure ==
 /\ owner.phase = "confirmed" /\ owner.stage = "failure"
 /\ IdentityGrant /\ (work.originalQuiet \/ Bug = "ignore_physical")
 /\ owner' = [owner EXCEPT !.phase = "terminal", !.consumed = TRUE,
      !.terminalError = IF Bug = "replace_failure" THEN "save_error" ELSE
        IF owner.terminalError = "none" THEN owner.originalError ELSE @]
 /\ metrics' = [metrics EXCEPT
      !.exactAdoptions = @ /\ (owner.factStage = owner.stage /\ durable.stage = owner.stage /\ durable.state = "post"),
      !.validFailure = @ /\ Bug # "replace_failure",
      !.validContinuation = @ /\ ExactIdentity,
      !.physicalCustody = @ /\ work.originalQuiet /\ work.quiet]
 /\ UNCHANGED <<durable, work, clients, authority, reads>>

ReleaseOwner ==
 /\ owner.held /\ owner.phase \in {"installed", "terminal", "unadmitted"}
 /\ IdentityGrant
 /\ work.originalQuiet /\ work.quiet
 /\ owner' = [owner EXCEPT !.held = FALSE, !.controlsHeld = FALSE]
 /\ UNCHANGED <<durable, work, clients, metrics, authority, reads>>

CancelObserver(i) ==
 /\ i \in Observers /\ clients.status[i] = "pending"
 /\ clients' = [clients EXCEPT !.status[i] = "cancelled", !.cancelled = @ \cup {i}]
 /\ owner' = IF Bug = "observer_releases_owner" THEN [owner EXCEPT !.held = FALSE] ELSE owner
 /\ metrics' = [metrics EXCEPT !.retainedCustody = @ /\ Bug # "observer_releases_owner"]
 /\ UNCHANGED <<durable, work, authority, reads>>

DuplicateReady ==
 /\ Bug = "duplicate_install" /\ owner.phase = "installed" /\ metrics.installations = 1
 /\ metrics' = [metrics EXCEPT !.installations = 2]
 /\ UNCHANGED <<owner, durable, work, clients, authority, reads>>

ReplayPreparedWork ==
 /\ Bug = "replay_preparation" /\ owner.consumed /\ metrics.preparations = 1
 /\ metrics' = [metrics EXCEPT !.preparations = 2]
 /\ UNCHANGED <<owner, durable, work, clients, authority, reads>>

MayDrift == ~StableAuthority \/ (work.state # "recorded" /\ owner.phase # "confirmed" /\ owner.phase # "preparing")
DriftAuthority ==
 /\ Drift # "none" /\ ~authority.changed /\ MayDrift
 /\ authority' = [authority EXCEPT
      !.owner = IF Drift = "identity" THEN 2 ELSE @,
      !.capturedDomain = IF Drift = "domain" THEN FALSE ELSE @,
      !.freshGuard = IF Drift = "guard" THEN FALSE ELSE @,
      !.changed = TRUE]
 /\ UNCHANGED <<owner, durable, work, clients, metrics, reads>>

Next == OriginalFails \/ OriginalCompletes \/ RestoreRead \/ CancelParent \/
 BeginAttempt \/ UnknownIsNotRefusal \/ RecordAttempt \/ WorkerCompletes \/
 DeliverAttempt \/ BeginPreparation \/ CompletePreparation \/ StopAfterProof \/ StopBeforeActivation \/ StopWithoutAdmission \/ AdoptActivation \/
 AdoptFailure \/ ReleaseOwner \/ (\E i \in Observers : CancelObserver(i)) \/
 DuplicateReady \/ ReplayPreparedWork \/ DriftAuthority

Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(OriginalFails) /\ WF_vars(OriginalCompletes) /\
 WF_vars(RestoreRead) /\ WF_vars(BeginAttempt) /\ WF_vars(RecordAttempt) /\
 WF_vars(WorkerCompletes) /\ WF_vars(DeliverAttempt) /\ WF_vars(BeginPreparation) /\
 WF_vars(CompletePreparation) /\ WF_vars(StopAfterProof) /\ WF_vars(StopBeforeActivation) /\ WF_vars(StopWithoutAdmission) /\ WF_vars(AdoptActivation) /\
 WF_vars(AdoptFailure) /\ WF_vars(ReleaseOwner)

TypeOK == owner.stage \in Stages /\ durable.stage \in Stages /\
 owner.phase \in {"uncertain", "confirmed", "preparing", "installed", "terminal", "unadmitted"} /\
 durable.state \in {"pre", "post", "divergent"} /\
 work.state \in {"idle", "running", "recorded"} /\
 owner.fact \in {"unknown", "pre", "post"} /\
 metrics.installations \in 0..2 /\ metrics.preparations \in 0..2
NoPreparationReplay == metrics.preparations <= 1
OneInstallation == metrics.installations <= 1
ExactStageProof == metrics.exactAdoptions
ExactRetry == metrics.safeWrites
NoProposalReplay == metrics.proposalRebuilds = 0 /\ metrics.participantReplays = 0
CurrentAuthority == metrics.validContinuation
OriginalControls == metrics.controlledContinuation
PhysicalCustody == metrics.physicalCustody
RetainedCustody == metrics.retainedCustody
SubmissionKnowledge == metrics.validSubmission
OriginalFailure == metrics.validFailure
ClosedOriginal == clients.original # "complete"
IndependentObservers == \A i \in clients.cancelled : clients.status[i] = "cancelled"
NoEarlyRelease == ~owner.held => owner.phase \in {"installed", "terminal", "unadmitted"}
UnadmittedHasNoJob == owner.phase = "unadmitted" =>
 durable.stage = "admission" /\ durable.state = "pre" /\
 metrics.preparations = 0 /\ metrics.installations = 0 /\ metrics.providerCalls = 0
EventuallyReleased == <>~owner.held
NeverInstalled == metrics.installations = 0
NeverTerminal == owner.phase # "terminal"
NeverUnadmittedStop == owner.phase # "unadmitted"
NeverRetried == durable.writes = 0
NeverCancelledAfterClose == ~(owner.parentCancelled /\ clients.original = "failed" /\ owner.phase = "terminal")
=============================================================================
