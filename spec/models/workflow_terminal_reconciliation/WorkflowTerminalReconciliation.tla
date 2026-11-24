---------------- MODULE WorkflowTerminalReconciliation ----------------
EXTENDS Naturals, FiniteSets

CONSTANTS InitialProfile, AllowRequests, AllowStop, AllowFaults,
          AllowStorageChange, AllowReuse, Bug

VARIABLE s

Observers == {1, 2}
Attempts == {1, 2}
Live == s.runtime \in {"running", "draining"}
OwnerCanAct == Live \/ s.runtime = "stopping"
Pending == {o \in Observers : s.observers[o] = "pending"}
Proved == s.proof \in {"post", "pre"}
NoPhysicalWork == ~s.originalPhysical /\ s.physicalReads = {}
TerminalObservations == {"post", "pre", "unresolved", "unavailable", "cancelled"}

Init ==
  LET fresh == InitialProfile = "fresh"
      requested == InitialProfile \in {"post_requested", "pre_requested", "unreadable_requested", "stopped_requested", "draining_requested"}
      store == IF InitialProfile \in {"pre_requested", "fresh", "physical"} THEN "pre" ELSE "post"
  IN s = [runtime |-> IF InitialProfile = "stopped_requested" THEN "stopped" ELSE IF InitialProfile = "draining_requested" THEN "draining" ELSE "running",
          readable |-> InitialProfile # "unreadable_requested",
          storage |-> store, committed |-> store = "post",
          originalPhysical |-> fresh \/ InitialProfile = "physical", unknownEmitted |-> ~fresh,
          route |-> IF fresh THEN "live" ELSE "retired",
          custodyAccepted |-> ~fresh, acceptedToken |-> IF fresh THEN "none" ELSE "current",
          custodyRefused |-> FALSE, waiterHeld |-> fresh,
          originalObserver |-> IF fresh THEN "pending" ELSE "error",
          originalFailed |-> ~fresh, originalCancelled |-> FALSE, capabilityAvailable |-> ~fresh,
          obligationHeld |-> Bug # "save_without_record",
          owner |-> "old", released |-> FALSE, reused |-> FALSE,
          proof |-> "unknown", everPost |-> FALSE, everPre |-> FALSE,
          applied |-> FALSE, applyBlocked |-> FALSE,
          physicalReads |-> {}, activeAttempt |-> 0, nextAttempt |-> 0,
          replies |-> [i \in Attempts |-> "none"],
          delivered |-> {},
          attached |-> [i \in Attempts |-> {}],
          observers |-> [o \in Observers |-> IF requested /\ o = 1 THEN "pending" ELSE "idle"],
          originalSaveCount |-> 1, businessCount |-> 1,
          wrongRuntimeRead |-> FALSE, staleApplied |-> FALSE,
          sawStaleReply |-> FALSE, sawReadFailure |-> FALSE,
          sawDeliveryRefusal |-> FALSE, sawApplicationFailure |-> FALSE,
          sawMaterializationFailure |-> FALSE,
          shutdownReport |-> IF InitialProfile = "stopped_requested" THEN "incomplete" ELSE "none"]

(* The actual original write may still commit after its logical observation failed. *)
CommitOriginal ==
  /\ s.originalPhysical /\ s.storage = "pre"
  /\ s' = [s EXCEPT !.storage = "post", !.committed = TRUE]

FinishOriginal ==
  /\ s.originalPhysical
  /\ s' = [s EXCEPT !.originalPhysical = FALSE]

EmitUnknown ==
  /\ ~s.unknownEmitted
  /\ s' = [s EXCEPT !.unknownEmitted = TRUE]

RetireRoute ==
  /\ s.unknownEmitted /\ s.route = "live"
  /\ s' = [s EXCEPT !.route = "retired"]

(* Receiver retention is acknowledged explicitly; neither a Boolean nor enqueue is custody. *)
AcceptCustody ==
  /\ s.route = "retired" /\ ~s.custodyAccepted /\ ~s.custodyRefused /\ s.obligationHeld
  /\ OwnerCanAct
  /\ s' = [s EXCEPT !.custodyAccepted = TRUE, !.acceptedToken = "current"]

AcceptWrongCustody ==
  /\ Bug = "accept_wrong_receipt" /\ s.route = "retired" /\ ~s.custodyAccepted
  /\ OwnerCanAct
  /\ s' = [s EXCEPT !.custodyAccepted = TRUE, !.acceptedToken = "stale"]

RefuseCustody ==
  /\ AllowFaults /\ s.route = "retired" /\ ~s.custodyAccepted /\ ~s.custodyRefused
  /\ OwnerCanAct
  /\ s' = [s EXCEPT !.custodyRefused = TRUE]

DetachWaiter ==
  /\ s.route = "retired" /\ s.waiterHeld /\ OwnerCanAct
  /\ (s.custodyAccepted \/ Bug = "detach_without_acceptance")
  /\ s' = [s EXCEPT !.waiterHeld = FALSE]

FailOriginalObserver ==
  /\ s.custodyAccepted /\ ~s.waiterHeld /\ s.originalObserver = "pending" /\ OwnerCanAct
  /\ s' = [s EXCEPT !.originalObserver = "error", !.originalFailed = TRUE, !.capabilityAvailable = TRUE,
       !.obligationHeld = IF Bug = "ordinary_error_releases" THEN FALSE ELSE @,
       !.owner = IF Bug = "ordinary_error_releases" THEN "none" ELSE @]

(* Application observation may fail while Engine still holds its source waiter.
   The separately retained domain evidence, not transport detach, permits this. *)
ReportDeliveryFailure ==
  /\ AllowFaults /\ s.unknownEmitted /\ s.originalObserver = "pending"
  /\ s.obligationHeld
  /\ s' = [s EXCEPT !.originalObserver = "error", !.originalFailed = TRUE,
                     !.capabilityAvailable = TRUE]

(* Cancelling observation cannot discard the accepted write or its lookup path. *)
CancelOriginalObserver ==
  /\ AllowFaults /\ s.originalObserver = "pending"
  /\ s' = [s EXCEPT !.originalObserver = "cancelled", !.originalCancelled = TRUE]

LookupRecovery ==
  /\ s.unknownEmitted /\ s.obligationHeld /\ ~s.capabilityAvailable
  /\ s' = [s EXCEPT !.capabilityAvailable = TRUE]

Request(o) ==
  /\ AllowRequests /\ s.capabilityAvailable /\ s.observers[o] = "idle"
  /\ s' = [s EXCEPT !.observers[o] = "pending", !.applyBlocked = FALSE,
       !.attached = IF s.activeAttempt \in Attempts
                     THEN [@ EXCEPT ![s.activeAttempt] = @ \cup {o}] ELSE @]

(* This is an explicitly supplied host input after physical return, not a timer. *)
SupplyAfterPhysical ==
  /\ InitialProfile = "physical" /\ ~s.originalPhysical /\ s.observers[1] = "idle"
  /\ s.capabilityAvailable
  /\ s' = [s EXCEPT !.observers[1] = "pending"]

ObserveUnavailable ==
  /\ ~Live /\ ~s.released /\ Pending # {}
  /\ s' = [s EXCEPT !.observers = [o \in Observers |->
              IF o \in Pending THEN "unavailable" ELSE @ [o]]]

ObserveCustodyUnavailable ==
  /\ Live /\ ~s.custodyAccepted /\ Pending # {}
  /\ s' = [s EXCEPT !.observers = [o \in Observers |->
              IF o \in Pending THEN "unavailable" ELSE @ [o]]]

ObservePhysicalUnavailable ==
  /\ Live /\ s.originalPhysical /\ Pending # {}
  /\ s' = [s EXCEPT !.observers = [o \in Observers |->
              IF o \in Pending THEN "unavailable" ELSE @ [o]]]

StartRead ==
  /\ Pending # {} /\ ~Proved /\ s.activeAttempt = 0
  /\ s.capabilityAvailable /\ s.custodyAccepted /\ ~s.waiterHeld
  /\ s.nextAttempt < 2 /\ s.owner = "old" /\ s.obligationHeld
  /\ (Live \/ Bug = "runtime_hop")
  /\ (~s.originalPhysical \/ Bug = "read_before_write_finished")
  /\ (s.physicalReads = {} \/ Bug = "cancel_permits_overlap")
  /\ LET i == s.nextAttempt + 1
     IN s' = [s EXCEPT !.nextAttempt = i, !.activeAttempt = i,
          !.physicalReads = @ \cup {i}, !.attached[i] = Pending,
          !.wrongRuntimeRead = @ \/ ~Live]

CancelObservation(o) ==
  /\ AllowFaults /\ s.observers[o] = "pending"
  /\ s' = [s EXCEPT !.observers[o] = "cancelled",
       !.activeAttempt = IF Bug = "cancel_permits_overlap" THEN 0 ELSE @,
       !.obligationHeld = IF Bug = "observer_cancellation_drops_record" THEN FALSE ELSE @]

ReadStorage(i) ==
  /\ i \in s.physicalReads /\ s.replies[i] = "none"
  /\ LET reply == IF ~s.readable THEN "unavailable"
                  ELSE IF s.storage = "other" /\ Bug = "later_equal_snapshot"
                       THEN "post"
                  ELSE IF s.storage = "other" THEN "conflict"
                  ELSE s.storage
     IN s' = [s EXCEPT !.replies[i] = reply,
          !.sawReadFailure = @ \/ reply = "unavailable"]

FinishRead(i) ==
  /\ i \in s.physicalReads /\ s.replies[i] # "none"
  /\ s' = [s EXCEPT !.physicalReads = @ \ {i}]

PublishRead(i) ==
  /\ i = s.activeAttempt /\ s.replies[i] # "none" /\ i \notin s.delivered
  /\ Live /\ s.owner = "old" /\ s.obligationHeld
  /\ LET reply == s.replies[i]
         fact == IF reply \in {"post", "pre"} THEN reply ELSE s.proof
     IN s' = [s EXCEPT !.delivered = @ \cup {i}, !.proof = fact,
          !.everPost = @ \/ fact = "post", !.everPre = @ \/ fact = "pre"]

RefuseReadDelivery(i) ==
  /\ AllowFaults /\ i = s.activeAttempt /\ s.replies[i] # "none"
  /\ i \notin s.delivered /\ ~s.sawDeliveryRefusal
  /\ s' = [s EXCEPT !.sawDeliveryRefusal = TRUE,
       !.obligationHeld = IF Bug = "delivery_refusal_drops_record" THEN FALSE ELSE @]

ApplyEvidence ==
  /\ Proved /\ ~s.applied /\ ~s.applyBlocked /\ Live /\ s.owner = "old"
  /\ s.obligationHeld
  /\ (s.activeAttempt # 0 \/ Pending # {})
  /\ s' = [s EXCEPT !.applied = TRUE]

ApplicationFailure ==
  /\ AllowFaults /\ Proved /\ ~s.applied /\ ~s.sawApplicationFailure
  /\ Live /\ s.activeAttempt # 0
  /\ s' = [s EXCEPT !.sawApplicationFailure = TRUE, !.applyBlocked = TRUE]

MaterializationFailure ==
  /\ AllowFaults /\ s.proof = "post" /\ ~s.sawMaterializationFailure
  /\ s' = [s EXCEPT !.sawMaterializationFailure = TRUE,
       !.proof = IF Bug = "erase_proof_on_observer_error" THEN "unknown" ELSE @]

ReleaseOwner ==
  /\ Proved /\ s.owner = "old" /\ Live
  /\ s.custodyAccepted /\ s.acceptedToken = "current" /\ ~s.waiterHeld
  /\ (s.applied \/ Bug = "release_before_application")
  /\ (NoPhysicalWork \/ Bug = "release_before_physical_end")
  /\ s' = [s EXCEPT !.released = TRUE, !.owner = "none", !.obligationHeld = FALSE,
       !.originalObserver = IF Bug = "resurrect_original" THEN "success" ELSE @]

FinishAttempt ==
  /\ s.activeAttempt \in Attempts
  /\ s.activeAttempt \in s.delivered /\ s.activeAttempt \notin s.physicalReads
  /\ (~Proved \/ s.released \/ s.applyBlocked)
  /\ LET i == s.activeAttempt
         result == IF Proved THEN s.proof
                   ELSE IF s.replies[i] = "conflict" THEN "unresolved" ELSE "unavailable"
     IN s' = [s EXCEPT !.activeAttempt = 0,
          !.observers = [o \in Observers |->
             IF o \in s.attached[i] /\ s.observers[o] = "pending" THEN result ELSE @ [o]]]

ObserveCachedReceipt ==
  /\ s.released /\ Pending # {}
  /\ s' = [s EXCEPT !.observers = [o \in Observers |->
              IF o \in Pending THEN s.proof ELSE @ [o]]]

(* A known pre-state does not authorize another save in this read-only slice. *)
ReplayWrite ==
  /\ Bug = "replay_write" /\ s.proof = "pre"
  /\ s' = [s EXCEPT !.originalSaveCount = @ + 1]

StorageUnavailable ==
  /\ AllowStorageChange /\ s.readable /\ ~Proved
  /\ s' = [s EXCEPT !.readable = FALSE]

StorageRecovered ==
  /\ AllowStorageChange /\ ~s.readable
  /\ s' = [s EXCEPT !.readable = TRUE]

LaterConflictingRevision ==
  /\ AllowStorageChange /\ ~s.originalPhysical /\ s.storage # "other"
  /\ ~Proved /\ s.physicalReads = {}
  /\ s' = [s EXCEPT !.storage = "other"]

BeginDrain ==
  /\ AllowStop /\ s.runtime = "running"
  /\ s' = [s EXCEPT !.runtime = "draining"]

StopRuntime ==
  /\ AllowStop /\ Live
  /\ s' = [s EXCEPT !.runtime = "stopping", !.route = "retired",
       !.unknownEmitted = TRUE,
       !.shutdownReport = IF (s.released /\ s.owner # "new" /\ NoPhysicalWork /\ ~s.waiterHeld)
                               \/ Bug = "shutdown_drops_record" THEN "complete" ELSE "incomplete",
       !.obligationHeld = IF Bug = "shutdown_drops_record" THEN FALSE ELSE @]

(* Failure cleanup is exclusive while stopping; no owner action runs after join. *)
FinishStop ==
  /\ s.runtime = "stopping"
  /\ ((~s.waiterHeld /\ s.originalObserver \in {"error", "cancelled"}) \/ s.custodyRefused)
  /\ s' = [s EXCEPT !.runtime = "stopped"]

ReuseWorkflowID ==
  /\ AllowReuse /\ s.released /\ s.owner = "none" /\ ~s.reused /\ Live
  /\ s' = [s EXCEPT !.owner = "new", !.reused = TRUE]

DeliverOldReply ==
  /\ s.reused /\ s.delivered # {} /\ ~s.sawStaleReply
  /\ s' = [s EXCEPT !.sawStaleReply = TRUE,
       !.owner = IF Bug = "stale_release" THEN "none" ELSE @,
       !.staleApplied = Bug = "stale_release"]

Next == CommitOriginal \/ FinishOriginal \/ EmitUnknown \/ RetireRoute
        \/ AcceptCustody \/ AcceptWrongCustody \/ RefuseCustody \/ DetachWaiter \/ FailOriginalObserver
        \/ CancelOriginalObserver \/ LookupRecovery \/ ReportDeliveryFailure
        \/ (\E o \in Observers : Request(o) \/ CancelObservation(o))
        \/ ObserveUnavailable \/ ObserveCustodyUnavailable \/ ObservePhysicalUnavailable
        \/ SupplyAfterPhysical \/ StartRead
        \/ (\E i \in Attempts : ReadStorage(i) \/ FinishRead(i)
                                \/ PublishRead(i) \/ RefuseReadDelivery(i))
        \/ ApplyEvidence \/ ApplicationFailure \/ MaterializationFailure
        \/ ReleaseOwner \/ FinishAttempt \/ ObserveCachedReceipt \/ ReplayWrite
        \/ StorageUnavailable \/ StorageRecovered \/ LaterConflictingRevision
        \/ BeginDrain \/ StopRuntime \/ FinishStop \/ ReuseWorkflowID \/ DeliverOldReply

Spec == Init /\ [][Next]_s

(* An explicit caller request and reliable storage are initial profile premises.
   Fairness on I/O completion means that the call returns, not CPU scheduling. *)
OwnerFairness == WF_s(EmitUnknown) /\ WF_s(RetireRoute)
                 /\ WF_s(AcceptCustody) /\ WF_s(DetachWaiter)
                 /\ WF_s(FailOriginalObserver) /\ WF_s(StartRead)
                 /\ WF_s(ApplyEvidence)
                 /\ WF_s(ReleaseOwner) /\ WF_s(FinishAttempt)
                 /\ WF_s(ObserveCachedReceipt) /\ WF_s(ObserveUnavailable)
ReadFairness == \A i \in Attempts : WF_s(ReadStorage(i)) /\ WF_s(FinishRead(i)) /\ WF_s(PublishRead(i))
ProgressSpec == Spec /\ OwnerFairness /\ ReadFairness /\ WF_s(FinishOriginal)
PhysicalProgressSpec == ProgressSpec /\ WF_s(SupplyAfterPhysical)
MissingPhysicalPremiseSpec == Spec /\ OwnerFairness /\ ReadFairness /\ WF_s(SupplyAfterPhysical)
MissingReadPremiseSpec == Spec /\ OwnerFairness /\ WF_s(FinishOriginal)
                          /\ (\A i \in Attempts : WF_s(ReadStorage(i)) /\ WF_s(PublishRead(i)))

TypeOK ==
  /\ s.runtime \in {"running", "draining", "stopping", "stopped"}
  /\ s.storage \in {"pre", "post", "other"}
  /\ s.readable \in BOOLEAN /\ s.committed \in BOOLEAN
  /\ s.originalPhysical \in BOOLEAN /\ s.unknownEmitted \in BOOLEAN
  /\ s.route \in {"live", "retired"} /\ s.custodyAccepted \in BOOLEAN
  /\ s.acceptedToken \in {"none", "current", "stale"} /\ s.custodyRefused \in BOOLEAN
  /\ s.waiterHeld \in BOOLEAN /\ s.obligationHeld \in BOOLEAN
  /\ s.originalObserver \in {"pending", "error", "cancelled", "success"}
  /\ s.originalFailed \in BOOLEAN /\ s.originalCancelled \in BOOLEAN /\ s.capabilityAvailable \in BOOLEAN
  /\ s.owner \in {"old", "new", "none"}
  /\ s.released \in BOOLEAN /\ s.reused \in BOOLEAN
  /\ s.proof \in {"unknown", "post", "pre"}
  /\ s.applied \in BOOLEAN /\ s.applyBlocked \in BOOLEAN
  /\ s.everPost \in BOOLEAN /\ s.everPre \in BOOLEAN
  /\ s.physicalReads \subseteq Attempts
  /\ s.activeAttempt \in 0..2 /\ s.nextAttempt \in 0..2
  /\ s.replies \in [Attempts -> {"none", "post", "pre", "conflict", "unavailable"}]
  /\ s.delivered \subseteq Attempts
  /\ s.attached \in [Attempts -> SUBSET Observers]
  /\ s.observers \in [Observers -> TerminalObservations \cup {"idle", "pending"}]
  /\ s.originalSaveCount \in Nat /\ s.businessCount \in Nat
  /\ s.shutdownReport \in {"none", "incomplete", "complete"}

AcceptedResponsibilityRetained == ~s.released => s.obligationHeld /\ s.owner = "old"
WaiterDetachedOnlyAfterAcceptance == ~s.waiterHeld => s.custodyAccepted /\ s.acceptedToken = "current"
RefusedCustodyRetained == s.custodyRefused => s.waiterHeld /\ s.obligationHeld
OriginalErrorHasRetainedEvidence == s.originalObserver = "error" => s.obligationHeld \/ s.released
NoPrematureRelease == s.released => Proved /\ s.applied /\ NoPhysicalWork /\ s.custodyAccepted /\ s.acceptedToken = "current" /\ ~s.waiterHeld
ProofSound == (s.proof = "post" => s.committed) /\
              (s.proof = "pre" => ~s.committed /\ ~s.originalPhysical)
ConfirmedFactRetained == (s.everPost => s.proof = "post") /\ (s.everPre => s.proof = "pre")
OriginalObserverImmutable == (s.originalFailed => s.originalObserver = "error") /\
                             (s.originalCancelled => s.originalObserver = "cancelled")
OnePhysicalRead == Cardinality(s.physicalReads) <= 1
CapturedRuntimeOnly == ~s.wrongRuntimeRead
NoOldReplyChangesNewOwner == ~s.staleApplied /\ (s.reused => s.owner = "new")
ReadOnlyReconciliation == s.originalSaveCount = 1 /\ s.businessCount = 1
NoFalseCleanup == s.shutdownReport = "complete" => s.released /\ s.owner # "new" /\ NoPhysicalWork /\ ~s.waiterHeld
SuccessfulObservationHasProof == \A o \in Observers :
  (s.observers[o] = "post" => s.proof = "post") /\ (s.observers[o] = "pre" => s.proof = "pre")
ShutdownReportStable == [][s.shutdownReport # "none" => s'.shutdownReport = s.shutdownReport]_s
RecoveryObservationsImmutable == [][\A o \in Observers : s.observers[o] \in TerminalObservations => s'.observers[o] = s.observers[o]]_s
EventuallyResolved == <>s.released
EventuallyOriginalObserved == <>(s.originalObserver = "error")
EventuallyRequestObserved == <>(s.observers[1] \in TerminalObservations)

WitnessNoAcceptedDetach == ~(s.custodyAccepted /\ ~s.waiterHeld /\ s.originalFailed)
WitnessNoPostResolution == ~(s.released /\ s.proof = "post")
WitnessNoPreResolution == ~(s.released /\ s.proof = "pre")
WitnessNoPhysicalError == ~(s.originalFailed /\ s.originalPhysical)
WitnessNoCancelledResolution == ~(s.observers[1] = "cancelled" /\ s.released)
WitnessNoLateReply == ~s.sawStaleReply
WitnessNoMaterializationFailure == ~(s.sawMaterializationFailure /\ s.proof = "post")
WitnessNoRejectedDelivery == ~(s.sawDeliveryRefusal /\ s.obligationHeld)
WitnessNoStoppedRetention == ~(s.runtime = "stopped" /\ s.obligationHeld /\ s.shutdownReport = "incomplete")
WitnessNoEarlyPublicError == ~(s.originalFailed /\ s.waiterHeld /\ ~s.custodyAccepted /\ s.obligationHeld)
WitnessNoCancelledOriginalRecovery == ~(s.originalCancelled /\ s.released)
WitnessNoCustodyRefusal == ~(s.custodyRefused /\ s.runtime = "stopped" /\ s.waiterHeld /\ s.obligationHeld)
WitnessNoRetryResolution == ~(s.sawReadFailure /\ s.nextAttempt = 2 /\ s.released)
=============================================================================
