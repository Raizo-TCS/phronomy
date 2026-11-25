-------------------- MODULE DispatchPreparationRecovery --------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Outcome, InitialProof, BarrierEntered, Fault, FreshCaller, PhysicalReturn, Readable, Settles,
          CompleteProposal, RetryCaller, RetryReplyLost, InitialDispatch,
          MaterializationError, ContinuationAvailable, CompletionReceipt, ObserveClients, Bug
VARIABLES save, storage, worker, owner, dispatch, clients
vars == <<save, storage, worker, owner, dispatch, clients>>
Observers == 1..2
ActiveObservers == IF ObserveClients THEN Observers ELSE {}
FaultEnabled(name) == Fault = "all" \/ Fault = name
ExactOwner == owner.generation = 1
CanApply == ExactOwner \/ Bug = "stale_owner"
PhysicalQuiet == save.physical /\ worker.phase = "idle"

(* The original observation has ended, but its save worker may still run.
   A captured proposal contains finalized input and stable invocation identities. *)
Init ==
 /\ save = [phase |-> "queued", handle |-> TRUE, physical |-> FALSE]
 /\ storage = [actual |-> "pre", settled |-> FALSE, epoch |-> 0,
      writes |-> IF BarrierEntered THEN 1 ELSE 0, interference |-> FALSE, staleWrite |-> FALSE]
 /\ worker = [phase |-> "idle", kind |-> "read", result |-> "unknown",
      handle |-> TRUE, physical |-> FALSE, readEpoch |-> 0,
      overlap |-> FALSE, generation |-> 1]
 /\ owner = [held |-> TRUE, live |-> TRUE, generation |-> 1,
      mutatedGeneration |-> 0, wanted |-> FALSE, request |-> "read",
      known |-> "unknown", applied |-> FALSE, applications |-> 0, builds |-> 1,
      continuation |-> "pending", handoffs |-> 0,
      cancelRequested |-> FALSE, ready |-> "pending"]
 /\ dispatch = [knowledge |-> InitialDispatch,
      admissions |-> IF InitialDispatch = "none" THEN 0 ELSE 1,
      effects |-> 0, cancellationViolated |-> FALSE,
      materializationViolated |-> FALSE, authorizedWithoutProof |-> FALSE]
 /\ clients = [original |-> "failed",
      receipt |-> [i \in Observers |-> "unused"],
      receiptClosed |-> [i \in Observers |-> FALSE],
      execution |-> [i \in Observers |-> "unused"],
      executionClosed |-> [i \in Observers |-> FALSE]]

SaveEnter ==
 /\ save.phase = "queued"
 /\ save' = [save EXCEPT !.phase = "running"]
 /\ UNCHANGED <<storage, worker, owner, dispatch, clients>>
SaveRecord ==
 /\ save.phase = "running"
 /\ InitialProof # "post" \/ (storage.settled /\ storage.actual = "post")
 /\ save' = [save EXCEPT !.phase = "recorded"]
 /\ UNCHANGED <<storage, worker, owner, dispatch, clients>>
SaveQuiet ==
 /\ PhysicalReturn /\ save.phase = "recorded"
 /\ save' = [save EXCEPT !.phase = "quiet"]
 /\ UNCHANGED <<storage, worker, owner, dispatch, clients>>
ObserveSaveQuiet ==
 /\ save.phase = "quiet" /\ save.handle /\ ~save.physical
 /\ save' = [save EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<storage, worker, owner, dispatch, clients>>
SettleSave ==
 /\ BarrierEntered /\ Settles /\ save.phase # "queued" /\ ~storage.settled
 /\ storage' = [storage EXCEPT !.settled = TRUE, !.actual = Outcome,
      !.epoch = IF Outcome = "pre" THEN 0 ELSE 1]
 /\ UNCHANGED <<save, worker, owner, dispatch, clients>>
LoseSaveHandle ==
 /\ FaultEnabled("lost_save_handle") /\ save.handle /\ ~save.physical
 /\ save' = [save EXCEPT !.handle = FALSE]
 /\ UNCHANGED <<storage, worker, owner, dispatch, clients>>
DeliverReady ==
 /\ save.phase \in {"recorded", "quiet"} /\ owner.ready = "pending"
 /\ owner' = [owner EXCEPT !.ready = "received"]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
RejectReady ==
 /\ FaultEnabled("ready_rejected") /\ owner.ready = "pending"
 /\ save.phase \in {"recorded", "quiet"}
 /\ owner' = [owner EXCEPT !.ready = "rejected",
      !.held = IF Bug = "ready_drops_custody" THEN FALSE ELSE @]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>

(* Requests are explicit new observations. A receipt cancellation does not
   cancel the retained worker or change another caller's execution observer. *)
FreshRead ==
 /\ FreshCaller /\ owner.live /\ ExactOwner /\ owner.held
 /\ ~owner.wanted /\ worker.phase = "idle"
 /\ owner' = [owner EXCEPT !.wanted = TRUE, !.request = "read"]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
FreshRetry ==
 /\ FreshCaller /\ RetryCaller /\ owner.live /\ ExactOwner /\ owner.held
 /\ ~owner.wanted /\ worker.phase = "idle" /\ owner.known # "post"
 /\ owner' = [owner EXCEPT !.wanted = TRUE, !.request = "retry"]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
OpenReceipt(i) ==
 /\ FreshCaller /\ owner.live /\ ExactOwner /\ clients.receipt[i] = "unused"
 /\ clients' = [clients EXCEPT !.receipt[i] = "pending"]
 /\ owner' = [owner EXCEPT !.wanted = TRUE]
 /\ UNCHANGED <<save, storage, worker, dispatch>>
CancelReceipt(i) ==
 /\ clients.receipt[i] = "pending"
 /\ clients' = [clients EXCEPT !.receipt[i] = "cancelled", !.receiptClosed[i] = TRUE]
 /\ owner' = [owner EXCEPT !.held = IF Bug = "observer_drops_custody" THEN FALSE ELSE @]
 /\ UNCHANGED <<save, storage, worker, dispatch>>

BeginRecovery ==
 /\ owner.live /\ ExactOwner /\ owner.held /\ owner.wanted
 /\ worker.phase = "idle" /\ CompleteProposal /\ owner.known # "post"
 /\ BarrierEntered
 /\ InitialProof # "post"
 /\ save.physical \/ Bug = "overlap_original"
 /\ worker' = [worker EXCEPT !.phase = "reading", !.kind = owner.request,
      !.result = "unknown", !.handle = TRUE, !.physical = FALSE,
      !.overlap = ~save.physical, !.generation = owner.generation]
 /\ owner' = [owner EXCEPT !.known = "unknown"]
 /\ UNCHANGED <<save, storage, dispatch, clients>>
RecordRead ==
 /\ worker.phase = "reading"
 /\ worker' = [worker EXCEPT !.phase = "compared", !.readEpoch = storage.epoch,
      !.result = IF ~Readable THEN "unknown"
        ELSE IF ~storage.settled /\ Bug # "local_return_is_settlement" THEN "unknown"
        ELSE IF storage.actual = "third" THEN
          IF Bug = "revision_only" THEN "post" ELSE "unknown"
        ELSE storage.actual]
 /\ UNCHANGED <<save, storage, owner, dispatch, clients>>
FinishComparison ==
 /\ worker.phase = "compared"
 /\ worker.kind = "read" \/ worker.result # "pre"
 /\ worker' = [worker EXCEPT !.phase = "recorded"]
 /\ UNCHANGED <<save, storage, owner, dispatch, clients>>
RetryCapturedProposal ==
 /\ worker.phase = "compared" /\ worker.kind = "retry" /\ worker.result = "pre"
 /\ (storage.actual = "pre" /\ storage.epoch = worker.readEpoch)
      \/ Bug = "stale_pre_write"
 /\ storage' = [storage EXCEPT !.actual = "post", !.epoch = @ + 1,
      !.writes = @ + 1,
      !.staleWrite = storage.actual # "pre" \/ storage.epoch # worker.readEpoch]
 /\ worker' = [worker EXCEPT !.phase = "recorded",
      !.result = IF RetryReplyLost THEN "unknown" ELSE "post"]
 /\ UNCHANGED <<save, owner, dispatch, clients>>
RejectChangedPre ==
 /\ worker.phase = "compared" /\ worker.kind = "retry" /\ worker.result = "pre"
 /\ storage.actual # "pre" \/ storage.epoch # worker.readEpoch
 /\ worker' = [worker EXCEPT !.phase = "recorded", !.result = "unknown"]
 /\ UNCHANGED <<save, storage, owner, dispatch, clients>>
RecoveryQuiet ==
 /\ worker.phase = "recorded"
 /\ worker' = [worker EXCEPT !.phase = "quiet"]
 /\ UNCHANGED <<save, storage, owner, dispatch, clients>>
ObserveRecoveryQuiet ==
 /\ worker.phase = "quiet" /\ worker.handle /\ ~worker.physical
 /\ worker' = [worker EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<save, storage, owner, dispatch, clients>>
LoseRecoveryHandle ==
 /\ FaultEnabled("lost_recovery_handle") /\ worker.phase # "idle"
 /\ worker.handle /\ ~worker.physical
 /\ worker' = [worker EXCEPT !.handle = FALSE]
 /\ UNCHANGED <<save, storage, owner, dispatch, clients>>
AcceptRecovery ==
 /\ owner.live /\ CanApply /\ owner.wanted
 /\ worker.phase = "quiet" /\ worker.physical
 /\ worker.generation = owner.generation \/ Bug = "stale_owner"
 /\ owner' = [owner EXCEPT !.known = worker.result,
      !.wanted = worker.result = "post", !.mutatedGeneration = owner.generation]
 /\ worker' = [worker EXCEPT !.phase = "idle"]
 /\ UNCHANGED <<save, storage, dispatch, clients>>

AdoptInitialResult ==
 /\ InitialProof = "post" /\ CompleteProposal /\ owner.held
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.known = "unknown"
 /\ PhysicalQuiet
 /\ owner' = [owner EXCEPT !.known = "post", !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>

InstallPrepared ==
 /\ owner.live /\ CanApply /\ owner.held /\ owner.wanted
 /\ owner.known = "post" /\ ~owner.applied /\ PhysicalQuiet
 /\ owner' = [owner EXCEPT !.applied = TRUE, !.applications = @ + 1,
      !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
ContinueOriginal ==
 /\ owner.known = "post"
 /\ ContinuationAvailable
 /\ owner.live /\ CanApply /\ owner.held /\ owner.applied
 /\ owner.continuation = "pending" /\ PhysicalQuiet
 /\ dispatch.knowledge = "none"
 /\ owner' = [owner EXCEPT !.continuation =
      IF owner.cancelRequested THEN "cancelled"
      ELSE IF MaterializationError THEN "failed" ELSE "resumed",
      !.handoffs = @ + 1, !.mutatedGeneration = owner.generation]
 /\ dispatch' = IF (owner.cancelRequested /\ Bug # "ignore_cancel")
      \/ (MaterializationError /\ Bug # "ignore_materialization") THEN dispatch
      ELSE [dispatch EXCEPT !.knowledge = "accepted", !.admissions = @ + 1,
       !.cancellationViolated = owner.cancelRequested,
       !.materializationViolated = MaterializationError,
       !.authorizedWithoutProof = owner.known # "post"]
 /\ UNCHANGED <<save, storage, worker, clients>>
LoseDispatchAdmission ==
 /\ owner.known = "post"
 /\ FaultEnabled("dispatch_unknown") /\ owner.live /\ CanApply
 /\ owner.held /\ owner.applied /\ owner.continuation = "pending"
 /\ ~owner.cancelRequested /\ ~MaterializationError /\ PhysicalQuiet
 /\ dispatch.knowledge = "none"
 /\ dispatch' = [dispatch EXCEPT !.knowledge = "unknown", !.admissions = @ + 1]
 /\ UNCHANGED <<save, storage, worker, owner, clients>>
CompleteExternal ==
 /\ dispatch.admissions > 0 /\ dispatch.effects = 0
 /\ dispatch' = [dispatch EXCEPT !.effects = 1]
 /\ UNCHANGED <<save, storage, worker, owner, clients>>
AcceptMatchingCompletion ==
 /\ CompletionReceipt /\ dispatch.effects = 1
 /\ dispatch.knowledge \in {"accepted", "unknown"}
 /\ owner.live /\ (ExactOwner \/ Bug = "stale_completion")
 /\ owner.held /\ owner.applied /\ owner.known = "post"
 /\ owner.continuation = "pending" /\ PhysicalQuiet
 /\ owner' = [owner EXCEPT !.continuation = "resumed", !.handoffs = @ + 1,
      !.mutatedGeneration = owner.generation]
 /\ dispatch' = [dispatch EXCEPT !.knowledge = "accepted"]
 /\ UNCHANGED <<save, storage, worker, clients>>

ClassifyNotPrepared ==
 /\ InitialProof = "error" /\ ~CompleteProposal
 /\ (~BarrierEntered \/ Bug = "missing_proposal_is_no_write")
 /\ owner.live /\ CanApply /\ owner.held /\ owner.wanted
 /\ owner.known = "unknown" /\ PhysicalQuiet
 /\ owner' = [owner EXCEPT !.known = "not_prepared", !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>

InstallUnpreparedStop ==
 /\ owner.known = "not_prepared" /\ ~owner.applied /\ PhysicalQuiet
 /\ owner.live /\ CanApply /\ owner.held /\ owner.wanted
 /\ owner' = [owner EXCEPT !.applied = TRUE, !.applications = @ + 1,
      !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>

HandOffUnpreparedStop ==
 /\ ContinuationAvailable /\ owner.known = "not_prepared" /\ owner.applied
 /\ owner.live /\ CanApply /\ owner.held /\ owner.wanted /\ PhysicalQuiet
 /\ owner.continuation = "pending"
 /\ owner' = [owner EXCEPT !.continuation = "stopped", !.handoffs = @ + 1,
      !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>

ReleasePreparation ==
 /\ owner.held /\ owner.continuation # "pending" /\ owner.applied
 /\ PhysicalQuiet /\ dispatch.knowledge # "unknown"
 /\ owner' = [owner EXCEPT !.held = FALSE, !.wanted = FALSE]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
DeliverReceipt(i) ==
 /\ clients.receipt[i] = "pending"
 /\ clients' = [clients EXCEPT !.receipt[i] = "complete",
      !.execution[i] = IF owner.continuation # "pending" THEN "pending" ELSE "unused"]
 /\ UNCHANGED <<save, storage, worker, owner, dispatch>>
CancelExecution(i) ==
 /\ clients.execution[i] = "pending"
 /\ clients' = [clients EXCEPT !.executionClosed[i] = TRUE,
      !.execution = IF Bug = "shared_observer" THEN
        [j \in Observers |-> IF clients.execution[j] = "pending" THEN "cancelled" ELSE clients.execution[j]]
        ELSE [clients.execution EXCEPT ![i] = "cancelled"]]
 /\ UNCHANGED <<save, storage, worker, owner, dispatch>>
CompleteExecution(i) ==
 /\ clients.execution[i] = "pending"
 /\ owner.continuation \in {"cancelled", "failed", "stopped"} \/ dispatch.effects > 0
 /\ clients' = [clients EXCEPT !.execution[i] = "complete"]
 /\ UNCHANGED <<save, storage, worker, owner, dispatch>>
Cancel ==
 /\ FaultEnabled("cancel") /\ ~owner.cancelRequested
 /\ owner' = [owner EXCEPT !.cancelRequested = TRUE]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
ChangeGeneration ==
 /\ FaultEnabled("owner_change") /\ owner.generation = 1
 /\ owner' = [owner EXCEPT !.generation = 2]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
Stop ==
 /\ FaultEnabled("shutdown") /\ owner.live
 /\ owner' = [owner EXCEPT !.live = FALSE]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
Interfere ==
 /\ FaultEnabled("interference") /\ storage.settled /\ ~storage.interference
 /\ storage.actual = "pre"
 /\ storage' = [storage EXCEPT !.actual = "third", !.epoch = @ + 1, !.interference = TRUE]
 /\ UNCHANGED <<save, worker, owner, dispatch, clients>>

(* Negative mutations deliberately violate a specific protocol boundary. *)
ReplayDispatch ==
 /\ Bug = "replay_dispatch" /\ dispatch.knowledge # "none"
 /\ dispatch.admissions = 1 /\ owner.known = "post"
 /\ dispatch' = [dispatch EXCEPT !.admissions = @ + 1]
 /\ UNCHANGED <<save, storage, worker, owner, clients>>
ReleaseUnknown ==
 /\ Bug = "unknown_cleanup" /\ owner.held
 /\ dispatch.knowledge = "unknown" \/ ~save.handle
      \/ (~worker.handle /\ worker.phase # "idle")
 /\ owner' = [owner EXCEPT !.held = FALSE]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
ApplyBeforeQuiet ==
 /\ Bug = "apply_before_physical" /\ ~save.physical /\ ~owner.applied
 /\ owner' = [owner EXCEPT !.applied = TRUE, !.applications = 1]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>
ReopenOriginal ==
 /\ Bug = "reopen_original" /\ clients.original = "failed"
 /\ owner.continuation # "pending"
 /\ clients' = [clients EXCEPT !.original = "complete"]
 /\ UNCHANGED <<save, storage, worker, owner, dispatch>>
Reapply ==
 /\ Bug = "duplicate_apply" /\ owner.applied /\ owner.applications = 1
 /\ owner' = [owner EXCEPT !.applications = @ + 1]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>

RebuildPreparation ==
 /\ Bug = "rebuild_proposal" /\ owner.known = "pre" /\ owner.builds = 1
 /\ owner' = [owner EXCEPT !.builds = 2]
 /\ UNCHANGED <<save, storage, worker, dispatch, clients>>

Next == SaveEnter \/ SaveRecord \/ SaveQuiet \/ ObserveSaveQuiet \/ SettleSave
 \/ LoseSaveHandle \/ DeliverReady \/ RejectReady \/ FreshRead \/ FreshRetry
 \/ BeginRecovery \/ RecordRead \/ FinishComparison \/ RetryCapturedProposal
 \/ RejectChangedPre \/ RecoveryQuiet \/ ObserveRecoveryQuiet \/ LoseRecoveryHandle
 \/ AcceptRecovery \/ AdoptInitialResult \/ InstallPrepared \/ ContinueOriginal \/ LoseDispatchAdmission
 \/ CompleteExternal \/ AcceptMatchingCompletion \/ ClassifyNotPrepared
 \/ InstallUnpreparedStop \/ HandOffUnpreparedStop \/ ReleasePreparation \/ Cancel \/ ChangeGeneration \/ Stop \/ Interfere
 \/ RebuildPreparation \/ ReplayDispatch \/ ReleaseUnknown \/ ApplyBeforeQuiet \/ ReopenOriginal \/ Reapply
 \/ (\E i \in ActiveObservers : OpenReceipt(i) \/ CancelReceipt(i) \/ DeliverReceipt(i)
      \/ CancelExecution(i) \/ CompleteExecution(i))
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(SaveEnter) /\ WF_vars(SaveRecord) /\ WF_vars(SaveQuiet)
 /\ WF_vars(ObserveSaveQuiet) /\ WF_vars(SettleSave) /\ WF_vars(FreshRead)
 /\ SF_vars(FreshRetry) /\ WF_vars(BeginRecovery) /\ WF_vars(RecordRead)
 /\ WF_vars(FinishComparison) /\ WF_vars(RetryCapturedProposal) /\ WF_vars(RejectChangedPre)
 /\ WF_vars(RecoveryQuiet) /\ WF_vars(ObserveRecoveryQuiet) /\ WF_vars(AcceptRecovery)
 /\ WF_vars(AdoptInitialResult) /\ WF_vars(InstallPrepared) /\ WF_vars(ContinueOriginal) /\ WF_vars(CompleteExternal)
 /\ WF_vars(AcceptMatchingCompletion) /\ WF_vars(ClassifyNotPrepared)
 /\ WF_vars(InstallUnpreparedStop) /\ WF_vars(HandOffUnpreparedStop)
 /\ WF_vars(ReleasePreparation)

TypeOK ==
 /\ save.phase \in {"queued", "running", "recorded", "quiet"}
 /\ save.handle \in BOOLEAN /\ save.physical \in BOOLEAN
 /\ storage.actual \in {"pre", "post", "third"} /\ storage.settled \in BOOLEAN
 /\ storage.epoch \in 0..3 /\ storage.writes \in 0..2
 /\ storage.interference \in BOOLEAN /\ storage.staleWrite \in BOOLEAN
 /\ worker.phase \in {"idle", "reading", "compared", "recorded", "quiet"}
 /\ worker.kind \in {"read", "retry"} /\ worker.result \in {"unknown", "pre", "post"}
 /\ worker.handle \in BOOLEAN /\ worker.physical \in BOOLEAN /\ worker.overlap \in BOOLEAN
 /\ worker.readEpoch \in 0..3 /\ worker.generation \in 1..2
 /\ owner.held \in BOOLEAN /\ owner.live \in BOOLEAN /\ owner.wanted \in BOOLEAN
 /\ owner.known \in {"unknown", "pre", "post", "not_prepared"} /\ owner.request \in {"read", "retry"}
 /\ owner.applied \in BOOLEAN /\ owner.applications \in 0..2 /\ owner.builds \in 1..2
 /\ owner.continuation \in {"pending", "resumed", "cancelled", "failed", "stopped"}
 /\ owner.handoffs \in 0..1 /\ owner.cancelRequested \in BOOLEAN
 /\ owner.ready \in {"pending", "received", "rejected"}
 /\ owner.generation \in 1..2 /\ owner.mutatedGeneration \in 0..2
 /\ dispatch.knowledge \in {"none", "accepted", "unknown"}
 /\ dispatch.admissions \in 0..2 /\ dispatch.effects \in 0..1
 /\ dispatch.cancellationViolated \in BOOLEAN /\ dispatch.materializationViolated \in BOOLEAN
 /\ dispatch.authorizedWithoutProof \in BOOLEAN
 /\ clients.original \in {"failed", "complete"}
 /\ \A i \in Observers : clients.receipt[i] \in {"unused", "pending", "cancelled", "complete"}
      /\ clients.execution[i] \in {"unused", "pending", "cancelled", "complete"}
      /\ clients.receiptClosed[i] \in BOOLEAN /\ clients.executionClosed[i] \in BOOLEAN
PositiveNoWriteProof == owner.known = "not_prepared" =>
 ~BarrierEntered /\ InitialProof = "error" /\ save.physical /\ storage.writes = 0
StoppedWithoutDispatch == owner.continuation = "stopped" => dispatch.admissions = 0
CompleteEvidence == owner.known = "post" => storage.settled /\ storage.actual = "post"
SettledPreEvidence == owner.known = "pre" => storage.settled
NoStaleProposalWrite == ~storage.staleWrite
NoWorkerOverlap == ~worker.overlap
PhysicalBeforeApplication == owner.applied => save.physical
NoPreparationReplay == owner.builds = 1
SingleApplication == owner.applications <= 1
ExactOwnerMutation == owner.mutatedGeneration \in {0, 1}
SingleDispatch == dispatch.admissions <= 1
CancellationBeforeDispatch == ~dispatch.cancellationViolated
MaterializationBeforeDispatch == ~dispatch.materializationViolated
ProofBeforeDispatch == ~dispatch.authorizedWithoutProof
CustodyUntilHandoff == ~owner.held => owner.continuation # "pending" /\ owner.applied
UnknownCustody == (dispatch.knowledge = "unknown" \/ ~save.handle
 \/ (~worker.handle /\ worker.phase # "idle")) => owner.held
QuietBeforeRelease == ~owner.held => save.physical /\ worker.phase = "idle"
ClosedOriginalStaysClosed == clients.original = "failed"
ClosedObserversStayClosed == \A i \in Observers :
 (clients.receiptClosed[i] => clients.receipt[i] = "cancelled") /\
 (clients.executionClosed[i] => clients.execution[i] = "cancelled")
IndependentObservers == \A i \in Observers : clients.execution[i] = "cancelled" => clients.executionClosed[i]
EventuallyResolved == <> (~owner.held)
NoStoppedWitness == ~(owner.known = "not_prepared" /\ owner.continuation = "stopped" /\ ~owner.held)
NoPreDispatchWitness == ~(owner.known = "pre" /\ owner.held /\ dispatch.admissions = 0)
NoReadyRefusalRecoveryWitness == ~(owner.ready = "rejected" /\ ~owner.held)
NoLatePhysicalWitness == ~(save.phase = "quiet" /\ ~save.handle /\ owner.held)
NoIndependentCompletionWitness == ~(clients.execution[1] = "cancelled" /\ clients.execution[2] = "complete")
NoUnknownAdmissionWitness == ~(dispatch.knowledge = "unknown" /\ dispatch.effects = 1 /\ owner.held)
NoCancellationHandoffWitness == ~(owner.continuation = "cancelled" /\ dispatch.admissions = 0 /\ ~owner.held)
=============================================================================
