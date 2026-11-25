----------------------- MODULE ChildApprovalRecovery -----------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Mode, Outcome, Approved, ChildCancelled, Fault, FreshCaller,
          Readable, ParentStable, ObserveClients, NextApproval, Bug
VARIABLES save, read, owner, durable, execution, clients
vars == <<save, read, owner, durable, execution, clients>>
Observers == 1..2
ActiveObservers == IF ObserveClients THEN Observers ELSE {}
Hosted == Mode = "hosted"
HasLiveBinding == Mode = "direct"
FaultEnabled(name) == Fault = "all" \/ Fault = name
ExactLocalOwner == owner.generation = 1
ExactLocalParent == ~Hosted \/ (owner.parentCurrent /\ owner.contextAlive)
CanApply == (ExactLocalOwner \/ Bug = "stale_owner") /\
            (ExactLocalParent \/ Bug = "stale_parent_wait")
DurableParentMatches == ~Hosted \/
  (durable.parentRevision = 1 /\ ~durable.parentCancelled)
PhysicalKnown == save.physical /\ read.physical

Init ==
 /\ save = [quiet |-> FALSE, physical |-> FALSE, handle |-> TRUE]
 /\ read = [phase |-> "idle", physical |-> TRUE, count |-> 0,
       child |-> "unknown", parent |-> FALSE]
 /\ owner = [held |-> TRUE, wanted |-> FALSE, known |-> "unknown",
       applied |-> FALSE, generation |-> 1, parentCurrent |-> TRUE,
       contextAlive |-> TRUE, freshProof |-> FALSE, restored |-> FALSE,
       restoredBinding |-> FALSE, attempts |-> 0, accepted |-> FALSE,
       admissionUnknown |-> FALSE, canonical |-> "none", handoff |-> FALSE,
       appliedGeneration |-> 0, parentValidAtApplication |-> TRUE,
       authorityAtAdmission |-> TRUE, refusalSpent |-> FALSE,
       physicalAtApplication |-> TRUE, parentProof |-> TRUE, contextRetired |-> FALSE]
 /\ durable = [child |-> Outcome, parentRevision |-> 1, parentCancelled |-> FALSE]
 /\ execution = [state |-> "idle", effects |-> 0, admissions |-> 0,
       canonicalCancelled |-> FALSE, detachActor |-> 0,
       detachAuthority |-> TRUE, secondWait |-> FALSE, physical |-> FALSE]
 /\ clients = [original |-> "closed",
       receipt |-> [i \in Observers |-> "unused"],
       observed |-> [i \in Observers |-> "unused"],
       observerClosed |-> [i \in Observers |-> FALSE],
       hostedHandle |-> [i \in Observers |-> FALSE],
       detachKey |-> [i \in Observers |-> 0], lateHostedHandle |-> FALSE]

(* Physical return and authoritative knowledge of that return are separate. *)
SaveReturns ==
 /\ ~save.quiet
 /\ save' = [save EXCEPT !.quiet = TRUE]
 /\ UNCHANGED <<read, owner, durable, execution, clients>>
ObservePhysical ==
 /\ save.quiet /\ save.handle /\ ~save.physical
 /\ save' = [save EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<read, owner, durable, execution, clients>>
LoseSaveHandle ==
 /\ FaultEnabled("lost_handle") /\ save.handle /\ ~save.physical
 /\ save' = [save EXCEPT !.handle = FALSE]
 /\ UNCHANGED <<read, owner, durable, execution, clients>>
FreshObservation ==
 /\ FreshCaller /\ owner.held /\ ~owner.wanted
 /\ owner' = [owner EXCEPT !.wanted = TRUE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
RequestReceipt(i) ==
 /\ FreshCaller /\ clients.receipt[i] = "unused"
 /\ clients' = [clients EXCEPT !.receipt[i] = "pending"]
 /\ owner' = [owner EXCEPT !.wanted = TRUE]
 /\ UNCHANGED <<save, read, durable, execution>>
BeginRead ==
 /\ owner.held /\ owner.wanted /\ ExactLocalOwner
 /\ save.physical \/ Bug = "ignore_physical"
 /\ ~owner.freshProof /\ ~owner.accepted
 /\ read.phase \in {"idle", "classified"} /\ read.count < 2
 /\ read' = [read EXCEPT !.phase = "running", !.physical = FALSE, !.count = @ + 1]
 /\ UNCHANGED <<save, owner, durable, execution, clients>>
ReadReturns ==
 /\ Readable /\ read.phase = "running"
 /\ read' = [read EXCEPT !.phase = "returned",
       !.child = durable.child, !.parent = DurableParentMatches]
 /\ UNCHANGED <<save, owner, durable, execution, clients>>
ReadPhysicallyCompletes ==
 /\ read.phase = "returned" /\ ~read.physical
 /\ read' = [read EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<save, owner, durable, execution, clients>>
Classify ==
 /\ read.phase = "returned" /\ read.physical /\ owner.held
 /\ owner' = [owner EXCEPT
       !.known = IF read.child \in {"pre", "post"} /\
          (read.parent \/ Bug = "child_only_proof") THEN read.child ELSE "unknown",
       !.freshProof = TRUE, !.parentProof = read.parent]
 /\ read' = [read EXCEPT !.phase = "classified"]
 /\ UNCHANGED <<save, durable, execution, clients>>

(* Changes during a read are represented by the snapshot observed at its return.
   Under ParentStable, unrelated durable writers cannot change authority after
   that return until the owner consumes it. A refused admission ends that unit. *)
CanChangeDurableParent ==
 ~ParentStable \/ read.phase \in {"idle", "running"} \/
 (owner.refusalSpent /\ owner.attempts = 1 /\ read.count = 1)
ChangeParentRevision ==
 /\ Hosted /\ FaultEnabled("parent_change") /\ durable.parentRevision = 1
 /\ ~owner.accepted /\ CanChangeDurableParent
 /\ durable' = [durable EXCEPT !.parentRevision = 2]
 /\ UNCHANGED <<save, read, owner, execution, clients>>
CancelParent ==
 /\ Hosted /\ FaultEnabled("parent_cancel") /\ ~durable.parentCancelled
 /\ ~owner.accepted /\ CanChangeDurableParent
 /\ durable' = [durable EXCEPT !.parentCancelled = TRUE]
 /\ UNCHANGED <<save, read, owner, execution, clients>>
ChangeChild ==
 /\ FaultEnabled("child_change") /\ durable.child # "different"
 /\ read.phase \in {"idle", "running"}
 /\ durable' = [durable EXCEPT !.child = "different"]
 /\ UNCHANGED <<save, read, owner, execution, clients>>
ChangeLocalParent ==
 /\ Hosted /\ FaultEnabled("local_parent_change") /\ owner.parentCurrent
 /\ owner' = [owner EXCEPT !.parentCurrent = FALSE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
LoseHostedContext ==
 /\ Hosted /\ FaultEnabled("lost_context") /\ owner.contextAlive
 /\ owner' = [owner EXCEPT !.contextAlive = FALSE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
ChangeOwner ==
 /\ FaultEnabled("owner_change") /\ owner.generation = 1
 /\ owner' = [owner EXCEPT !.generation = 2]
 /\ UNCHANGED <<save, read, durable, execution, clients>>

RestoreWait ==
 /\ owner.held /\ owner.wanted /\ owner.freshProof /\ owner.known = "pre"
 /\ CanApply /\ ~owner.applied
 /\ owner' = [owner EXCEPT !.applied = TRUE, !.restored = TRUE,
       !.restoredBinding = HasLiveBinding /\ Bug # "drop_direct_binding",
       !.held = FALSE, !.appliedGeneration = owner.generation,
       !.parentValidAtApplication = ExactLocalParent,
       !.physicalAtApplication = PhysicalKnown]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
ApplyPost ==
 /\ owner.held /\ owner.wanted /\ owner.freshProof /\ owner.known = "post"
 /\ CanApply /\ ~owner.applied
 /\ owner' = [owner EXCEPT !.applied = TRUE,
       !.canonical = IF Hosted /\ Bug # "plain_canonical_task" THEN "approval" ELSE "plain",
       !.appliedGeneration = owner.generation,
       !.parentValidAtApplication = ExactLocalParent,
       !.physicalAtApplication = PhysicalKnown]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
CanAdmit ==
 /\ owner.held /\ owner.wanted /\ owner.applied /\ owner.known = "post"
 /\ owner.freshProof /\ CanApply /\ ~owner.accepted
 /\ ~owner.admissionUnknown /\ owner.attempts < 2
RefuseAdmission ==
 /\ CanAdmit /\ FaultEnabled("refused_admission") /\ ~owner.refusalSpent
 /\ owner' = [owner EXCEPT !.attempts = @ + 1, !.wanted = FALSE,
       !.refusalSpent = TRUE, !.freshProof = Bug = "cached_parent_proof"]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
AdmitContinuation ==
 /\ CanAdmit
 /\ ~FaultEnabled("refused_admission") \/ owner.refusalSpent
 /\ owner' = [owner EXCEPT !.attempts = @ + 1,
       !.accepted = ~FaultEnabled("lost_admission_reply"),
       !.admissionUnknown = FaultEnabled("lost_admission_reply"),
       !.authorityAtAdmission = DurableParentMatches /\ ExactLocalParent]
 /\ execution' = [execution EXCEPT !.state = "running", !.admissions = @ + 1]
 /\ UNCHANGED <<save, read, durable, clients>>
MatchingSessionProgress ==
 /\ owner.admissionUnknown /\ execution.state \in {"running", "wait", "terminal"}
 /\ owner' = [owner EXCEPT !.accepted = TRUE, !.admissionUnknown = FALSE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
HandOff ==
 /\ owner.held /\ owner.accepted /\ ~owner.admissionUnknown
 /\ owner' = [owner EXCEPT !.held = FALSE, !.handoff = TRUE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
BusinessProgress ==
 /\ execution.state = "running"
 /\ execution' = [execution EXCEPT
       !.effects = @ + IF Approved /\ ~ChildCancelled THEN 1 ELSE 0,
       !.state = IF NextApproval /\ Approved /\ ~ChildCancelled THEN "wait" ELSE "terminal",
       !.secondWait = NextApproval /\ Approved /\ ~ChildCancelled]
 /\ UNCHANGED <<save, read, owner, durable, clients>>

ExecutionPhysicallyCompletes ==
 /\ execution.state \in {"terminal", "detached"} /\ ~execution.physical
 /\ execution' = [execution EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<save, read, owner, durable, clients>>
RetireHostedContext ==
 /\ Hosted /\ execution.physical /\ ~owner.contextRetired
 /\ owner' = [owner EXCEPT !.contextAlive = FALSE, !.contextRetired = TRUE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
CanIssueHostedHandle == Hosted /\ owner.contextAlive /\
  (~execution.physical \/ Bug = "return_retired_hosted_handle")

DeliverReceipt(i) ==
 /\ clients.receipt[i] = "pending" /\ ~owner.held
 /\ clients' = [clients EXCEPT !.receipt[i] = "delivered",
       !.observed[i] = IF owner.handoff THEN "pending" ELSE "unused",
       !.hostedHandle[i] = owner.handoff /\ CanIssueHostedHandle,
       !.lateHostedHandle = @ \/ (owner.handoff /\ CanIssueHostedHandle /\ execution.physical),
       !.detachKey[i] = IF owner.handoff /\ CanIssueHostedHandle /\
            owner.canonical = "approval" THEN 1 ELSE 0]
 /\ UNCHANGED <<save, read, owner, durable, execution>>
CancelReceipt(i) ==
 /\ FaultEnabled("observer_cancel")
 /\ clients.receipt[i] = "pending"
 /\ clients' = [clients EXCEPT !.receipt[i] = "closed"]
 /\ UNCHANGED <<save, read, owner, durable, execution>>
CancelObserver(i) ==
 /\ FaultEnabled("observer_cancel")
 /\ clients.observed[i] = "pending"
 /\ clients' = [clients EXCEPT !.observerClosed[i] = TRUE,
       !.observed = IF Bug = "shared_observer" THEN
          [j \in Observers |-> IF clients.observed[j] = "pending" THEN "closed" ELSE clients.observed[j]]
          ELSE [clients.observed EXCEPT ![i] = "closed"]]
 /\ execution' = [execution EXCEPT !.canonicalCancelled = Bug = "observer_cancels_work"]
 /\ UNCHANGED <<save, read, owner, durable>>
CompleteObserver(i) ==
 /\ clients.observed[i] = "pending" /\ execution.state \in {"terminal", "detached"}
 /\ clients' = [clients EXCEPT !.observed[i] = "complete"]
 /\ UNCHANGED <<save, read, owner, durable, execution>>
Detach(i) ==
 /\ Hosted /\ owner.handoff /\ execution.state = "wait"
 /\ clients.hostedHandle[i] /\ clients.detachKey[i] = 1
 /\ (ExactLocalOwner /\ ExactLocalParent) \/ Bug = "stale_detach"
 /\ execution' = [execution EXCEPT !.state = "detached", !.detachActor = i,
       !.detachAuthority = ExactLocalOwner /\ ExactLocalParent /\ owner.canonical = "approval"]
 /\ UNCHANGED <<save, read, owner, durable, clients>>

RetireAtSaveEnd ==
 /\ Bug = "save_end_retires_context" /\ Hosted /\ save.physical
 /\ owner.canonical # "none" /\ ~execution.physical /\ ~owner.contextRetired
 /\ owner' = [owner EXCEPT !.contextAlive = FALSE, !.contextRetired = TRUE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>

(* Mutants encode unsafe alternatives and are disabled in the normal model. *)
OldHandleDetaches ==
 /\ Bug = "old_handle_detach" /\ Hosted /\ execution.state = "wait"
 /\ execution' = [execution EXCEPT !.state = "detached", !.detachActor = 3]
 /\ UNCHANGED <<save, read, owner, durable, clients>>
DropCustody ==
 /\ Bug = "physical_return_is_release" /\ save.quiet /\ ~save.physical /\ owner.held
 /\ owner' = [owner EXCEPT !.held = FALSE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
ReplayUnknown ==
 /\ Bug = "unknown_is_unadmitted" /\ owner.admissionUnknown /\ execution.admissions = 1
 /\ owner' = [owner EXCEPT !.admissionUnknown = FALSE]
 /\ UNCHANGED <<save, read, durable, execution, clients>>
ReopenOriginal ==
 /\ Bug = "reopen_original" /\ owner.handoff /\ clients.original = "closed"
 /\ clients' = [clients EXCEPT !.original = "complete"]
 /\ UNCHANGED <<save, read, owner, durable, execution>>

Next == SaveReturns \/ ObservePhysical \/ LoseSaveHandle \/ FreshObservation
 \/ BeginRead \/ ReadReturns \/ ReadPhysicallyCompletes \/ Classify
 \/ ChangeParentRevision \/ CancelParent \/ ChangeChild \/ ChangeLocalParent
 \/ LoseHostedContext \/ ChangeOwner \/ RestoreWait \/ ApplyPost
 \/ RefuseAdmission \/ AdmitContinuation \/ MatchingSessionProgress \/ HandOff
 \/ BusinessProgress \/ ExecutionPhysicallyCompletes \/ RetireHostedContext \/ RetireAtSaveEnd \/ OldHandleDetaches \/ DropCustody \/ ReplayUnknown \/ ReopenOriginal
 \/ (\E i \in ActiveObservers : RequestReceipt(i) \/ DeliverReceipt(i) \/ CancelReceipt(i)
       \/ CancelObserver(i) \/ CompleteObserver(i) \/ Detach(i))
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(SaveReturns) /\ WF_vars(ObservePhysical)
 /\ WF_vars(FreshObservation) /\ WF_vars(BeginRead) /\ WF_vars(ReadReturns)
 /\ WF_vars(ReadPhysicallyCompletes) /\ WF_vars(Classify) /\ WF_vars(RestoreWait)
 /\ WF_vars(ApplyPost) /\ WF_vars(RefuseAdmission) /\ WF_vars(AdmitContinuation)
 /\ WF_vars(MatchingSessionProgress) /\ WF_vars(HandOff) /\ WF_vars(BusinessProgress)
 /\ WF_vars(ExecutionPhysicallyCompletes) /\ WF_vars(RetireHostedContext)
 /\ (\A i \in ActiveObservers : WF_vars(RequestReceipt(i)) /\ WF_vars(DeliverReceipt(i))
      /\ WF_vars(CompleteObserver(i)) /\ WF_vars(Detach(i)))

TypeOK ==
 /\ save.quiet \in BOOLEAN /\ save.physical \in BOOLEAN /\ save.handle \in BOOLEAN
 /\ read.phase \in {"idle", "running", "returned", "classified"}
 /\ read.physical \in BOOLEAN /\ read.count \in 0..2
 /\ read.child \in {"unknown", "pre", "post", "different"} /\ read.parent \in BOOLEAN
 /\ owner.held \in BOOLEAN /\ owner.wanted \in BOOLEAN /\ owner.applied \in BOOLEAN
 /\ owner.known \in {"unknown", "pre", "post"} /\ owner.generation \in 1..2
 /\ owner.parentCurrent \in BOOLEAN /\ owner.contextAlive \in BOOLEAN
 /\ owner.freshProof \in BOOLEAN /\ owner.restored \in BOOLEAN /\ owner.restoredBinding \in BOOLEAN
 /\ owner.attempts \in 0..2 /\ owner.accepted \in BOOLEAN /\ owner.admissionUnknown \in BOOLEAN
 /\ owner.canonical \in {"none", "plain", "approval"} /\ owner.handoff \in BOOLEAN
 /\ owner.appliedGeneration \in 0..2 /\ owner.parentValidAtApplication \in BOOLEAN
 /\ owner.authorityAtAdmission \in BOOLEAN /\ owner.refusalSpent \in BOOLEAN
 /\ owner.physicalAtApplication \in BOOLEAN /\ owner.parentProof \in BOOLEAN
 /\ owner.contextRetired \in BOOLEAN
 /\ durable.child \in {"pre", "post", "different"} /\ durable.parentRevision \in 1..2
 /\ durable.parentCancelled \in BOOLEAN
 /\ execution.state \in {"idle", "running", "wait", "terminal", "detached"}
 /\ execution.effects \in 0..2 /\ execution.admissions \in 0..2
 /\ execution.canonicalCancelled \in BOOLEAN /\ execution.detachActor \in 0..3
 /\ execution.detachAuthority \in BOOLEAN /\ execution.secondWait \in BOOLEAN
 /\ execution.physical \in BOOLEAN /\ clients.lateHostedHandle \in BOOLEAN
 /\ clients.original \in {"closed", "complete"}
 /\ \A i \in Observers : clients.receipt[i] \in {"unused", "pending", "delivered", "closed"}
     /\ clients.observed[i] \in {"unused", "pending", "closed", "complete"}
     /\ clients.observerClosed[i] \in BOOLEAN /\ clients.hostedHandle[i] \in BOOLEAN
     /\ clients.detachKey[i] \in 0..1
CompleteChildProof == owner.known = "post" => Outcome = "post"
CompleteParentProof == owner.known \in {"pre", "post"} => owner.parentProof
PhysicalBeforeApplication == owner.physicalAtApplication
ExactOwnerApplication == owner.appliedGeneration \in {0, 1}
ExactLocalParentApplication == owner.parentValidAtApplication
AuthorityAtAdmission == owner.authorityAtAdmission
CustodyUntilTransfer == ~owner.held => owner.restored \/ owner.handoff
UnknownPhysicalCustody == ~save.physical => owner.held
NoAdmissionReplay == execution.admissions <= 1
DecisionPermission == execution.effects > 0 => Approved /\ ~ChildCancelled /\ Outcome = "post"
HostedCanonicalAuthority == Hosted /\ owner.handoff => owner.canonical = "approval"
RestorationBinding == owner.restored => owner.restoredBinding = HasLiveBinding
FreshHandleAuthority == \A i \in Observers : clients.hostedHandle[i] => clients.detachKey[i] = 1
DetachAuthority == execution.state = "detached" => execution.detachAuthority /\ execution.detachActor \in Observers
ClosedOriginalStaysClosed == clients.original = "closed"
ClosedObserverStaysClosed == \A i \in Observers : clients.observerClosed[i] => clients.observed[i] = "closed"
IndependentObservers == \A i \in Observers : clients.observed[i] = "closed" => clients.observerClosed[i]
ObservationCannotCancelWork == ~execution.canonicalCancelled
ContextRetirementAfterExecution == owner.contextRetired => execution.physical
NoLateHostedHandle == ~clients.lateHostedHandle
NoDirectHostedHandle == ~Hosted => \A i \in Observers : ~clients.hostedHandle[i]
EventuallyResolved == <> ~owner.held
EventuallyDetached == <> (execution.state = "detached")
NoRestoredWitness == ~owner.restored
NoHostedHandoffWitness == ~(Hosted /\ owner.handoff /\ owner.canonical = "approval")
NoSecondDetachWitness == ~(execution.secondWait /\ execution.state = "detached")
NoIndependentCompletionWitness == ~(clients.observed[1] = "closed" /\ clients.observed[2] = "complete")
NoUnknownQuietWitness == ~(save.quiet /\ ~save.physical /\ ~save.handle /\ owner.held)
NoStaleParentRetainedWitness == ~(durable.parentRevision = 2 /\ owner.known = "unknown" /\ owner.held /\ read.phase = "classified")
NoPartialRetryBlockedWitness == ~(owner.refusalSpent /\ durable.parentRevision = 2 /\ read.count = 2 /\ owner.known = "unknown" /\ owner.held)
=============================================================================
