---------------------- MODULE ApprovalDecisionRecovery ----------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Outcome, Approved, Fault, FreshCaller, AdmissionQuery, ObserveClients, Bug
VARIABLES save, read, owner, plan, callers
vars == <<save, read, owner, plan, callers>>
Sessions == 0..2
Children == 1..2
Observers == 1..2
ActiveObservers == IF ObserveClients THEN Observers ELSE {}
FaultEnabled(name) == Fault = "all" \/ Fault = name
ExactOwner == owner.generation = 1
CanApply == ExactOwner \/ Bug = "stale_owner"

Init ==
 /\ save = [phase |-> IF Outcome = "refused" THEN "refused" ELSE "queued",
      handle |-> TRUE, physical |-> Outcome = "refused", completeProof |-> FALSE]
 /\ read = [phase |-> "idle", handle |-> TRUE, physical |-> FALSE,
      disposition |-> "unknown", starts |-> 0]
 /\ owner = [held |-> TRUE, live |-> TRUE, generation |-> 1, mutatedGeneration |-> 0,
      known |-> "unknown", wanted |-> FALSE, projection |-> 0, prepared |-> FALSE,
      cancelRequested |-> FALSE, cancelBound |-> FALSE, cancelProcessed |-> FALSE,
      handoff |-> "none", terminalOwned |-> FALSE, faultSpent |-> FALSE,
      unknownRegistration |-> FALSE]
 /\ plan = [i \in Sessions |-> [actual |-> "unregistered", accepted |-> FALSE,
      admittedCount |-> 0, effects |-> 0, abandoned |-> FALSE]]
 /\ callers = [original |-> "closed",
      receipt |-> [i \in Observers |-> "unused"],
      receiptClosed |-> [i \in Observers |-> FALSE],
      execution |-> [i \in Observers |-> "unused"],
      executionClosed |-> [i \in Observers |-> FALSE]]

SaveEnter ==
 /\ save.phase = "queued"
 /\ save' = [save EXCEPT !.phase = "running"]
 /\ UNCHANGED <<read, owner, plan, callers>>
SaveRecord ==
 /\ save.phase = "running"
 /\ save' = [save EXCEPT !.phase = "recorded", !.completeProof = TRUE]
 /\ UNCHANGED <<read, owner, plan, callers>>
SaveQuiet ==
 /\ save.phase = "recorded"
 /\ save' = [save EXCEPT !.phase = "quiet"]
 /\ UNCHANGED <<read, owner, plan, callers>>
ObserveSaveQuiet ==
 /\ save.phase = "quiet" /\ save.handle /\ ~save.physical
 /\ save' = [save EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<read, owner, plan, callers>>
LoseSaveHandle ==
 /\ FaultEnabled("lost_save_handle") /\ save.phase # "refused"
 /\ ~save.physical /\ save.handle
 /\ save' = [save EXCEPT !.handle = FALSE]
 /\ UNCHANGED <<read, owner, plan, callers>>

(* Each wake represents another explicit caller, never an automatic retry. *)
FreshObservation ==
 /\ FreshCaller /\ owner.live /\ ExactOwner /\ owner.held /\ ~owner.wanted
 /\ owner' = [owner EXCEPT !.wanted = TRUE]
 /\ UNCHANGED <<save, read, plan, callers>>
NamedObservation(i) ==
 /\ FreshCaller /\ owner.live /\ ExactOwner /\ callers.receipt[i] = "unused"
 /\ callers' = [callers EXCEPT !.receipt[i] = "pending"]
 /\ owner' = [owner EXCEPT !.wanted = TRUE]
 /\ UNCHANGED <<save, read, plan>>
CloseReceipt(i) ==
 /\ callers.receipt[i] = "pending"
 /\ callers' = [callers EXCEPT !.receipt[i] = "closed", !.receiptClosed[i] = TRUE]
 /\ UNCHANGED <<save, read, owner, plan>>

BeginRead ==
 /\ owner.live /\ ExactOwner /\ owner.wanted /\ owner.held
 /\ owner.known = "unknown" /\ save.physical /\ save.completeProof
 /\ read.phase = "idle" /\ read.starts < 2
 /\ read' = [read EXCEPT !.phase = "running", !.handle = TRUE,
      !.physical = FALSE, !.starts = @ + 1]
 /\ UNCHANGED <<save, owner, plan, callers>>
RecordRead ==
 /\ read.phase = "running"
 /\ read' = [read EXCEPT !.phase = "recorded",
      !.disposition = IF Outcome = "divergent" THEN
           IF Bug = "revision_only" THEN "post" ELSE "unknown"
           ELSE Outcome]
 /\ UNCHANGED <<save, owner, plan, callers>>
ReadQuiet ==
 /\ read.phase = "recorded"
 /\ read' = [read EXCEPT !.phase = "quiet"]
 /\ UNCHANGED <<save, owner, plan, callers>>
ObserveReadQuiet ==
 /\ read.phase = "quiet" /\ read.handle /\ ~read.physical
 /\ read' = [read EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<save, owner, plan, callers>>
LoseReadHandle ==
 /\ FaultEnabled("lost_read_handle") /\ read.phase # "idle"
 /\ ~read.physical /\ read.handle
 /\ read' = [read EXCEPT !.handle = FALSE]
 /\ UNCHANGED <<save, owner, plan, callers>>
ClassifyRead ==
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.known = "unknown"
 /\ save.physical /\ read.physical /\ read.phase = "quiet"
 /\ owner' = [owner EXCEPT !.known = read.disposition,
      !.wanted = read.disposition # "unknown"]
 /\ read' = [read EXCEPT !.phase = "idle"]
 /\ UNCHANGED <<save, plan, callers>>
ClassifyRefusal ==
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.known = "unknown"
 /\ save.phase = "refused" /\ save.physical
 /\ owner' = [owner EXCEPT !.known = "pre"]
 /\ UNCHANGED <<save, read, plan, callers>>

RestoreWait ==
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.known = "pre"
 /\ owner.handoff = "none" /\ save.physical /\ read.phase = "idle"
 /\ owner' = [owner EXCEPT !.projection = 2,
      !.cancelBound = Bug # "drop_cancellation", !.handoff = "wait",
      !.held = FALSE, !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, plan, callers>>
InstallRoot ==
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.known = "post"
 /\ owner.projection = 0 /\ save.physical /\ read.phase = "idle"
 /\ owner' = [owner EXCEPT !.projection = 1, !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, plan, callers>>
InstallExecution ==
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.known = "post"
 /\ owner.projection = 1
 /\ owner' = [owner EXCEPT !.projection = 2, !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, plan, callers>>
PreparePlan ==
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.known = "post"
 /\ owner.projection = 2 /\ ~owner.prepared
 /\ owner' = [owner EXCEPT !.prepared = TRUE, !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, plan, callers>>
InterruptInstall ==
 /\ FaultEnabled("install_interruption") /\ owner.projection = 1
 /\ owner.wanted /\ ~owner.faultSpent
 /\ owner' = [owner EXCEPT !.wanted = FALSE, !.faultSpent = TRUE]
 /\ UNCHANGED <<save, read, plan, callers>>

CanRegister(i) ==
 /\ owner.live /\ CanApply /\ owner.wanted /\ owner.prepared
 /\ owner.handoff = "none" /\ ~owner.unknownRegistration
 /\ ~plan[i].accepted /\ ~plan[i].abandoned
 /\ plan[i].actual = "unregistered" /\ plan[i].admittedCount < 2
 /\ i = 0 \/ plan[0].accepted
FaultAt(i, name) == FaultEnabled(name) /\ ~owner.faultSpent /\ i = 1

(* A response failure is queried in the same owner turn as registration.
   With no authoritative query, no later absence grants another registration. *)
Register(i) ==
 /\ CanRegister(i)
 /\ ~FaultAt(i, "before_registration") /\ ~FaultAt(i, "after_registration")
 /\ plan' = [plan EXCEPT ![i].actual = "admitted", ![i].accepted = TRUE,
      ![i].admittedCount = @ + 1]
 /\ owner' = [owner EXCEPT !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, callers>>
RejectRegistration(i) ==
 /\ CanRegister(i) /\ FaultAt(i, "before_registration")
 /\ owner' = [owner EXCEPT !.wanted = FALSE, !.faultSpent = TRUE]
 /\ UNCHANGED <<save, read, plan, callers>>
LoseRegistrationResponse(i) ==
 /\ CanRegister(i) /\ FaultAt(i, "after_registration")
 /\ plan' = [plan EXCEPT ![i].actual = "admitted", ![i].accepted = AdmissionQuery,
      ![i].admittedCount = @ + 1]
 /\ owner' = [owner EXCEPT !.wanted = FALSE, !.faultSpent = TRUE,
      !.unknownRegistration = ~AdmissionQuery, !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, callers>>
FinishChild(i) ==
 /\ i \in Children /\ plan[i].actual = "admitted"
 /\ plan' = [plan EXCEPT ![i].actual = "completed",
      ![i].effects = @ + IF Approved /\ ~owner.cancelRequested THEN 1 ELSE 0]
 /\ UNCHANGED <<save, read, owner, callers>>
FinishParent ==
 /\ plan[0].actual = "admitted"
 /\ \A i \in Children : plan[i].actual = "completed" \/ plan[i].abandoned
 /\ plan' = [plan EXCEPT ![0].actual = "completed"]
 /\ UNCHANGED <<save, read, owner, callers>>

HandOffContinuation ==
 /\ owner.live /\ CanApply /\ owner.known = "post" /\ owner.projection = 2
 /\ owner.handoff = "none" /\ ~owner.unknownRegistration
 /\ IF Bug = "parent_is_resumed" THEN plan[0].accepted
      ELSE \A i \in Sessions : plan[i].accepted
 /\ owner' = [owner EXCEPT !.handoff = "sessions", !.held = FALSE,
      !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, plan, callers>>
Cancel ==
 /\ FaultEnabled("cancel") /\ ~owner.cancelRequested
 /\ owner' = [owner EXCEPT !.cancelRequested = TRUE]
 /\ UNCHANGED <<save, read, plan, callers>>
ProcessRestoredCancellation ==
 /\ owner.handoff = "wait" /\ owner.cancelBound /\ owner.cancelRequested
 /\ ~owner.cancelProcessed
 /\ owner' = [owner EXCEPT !.cancelProcessed = TRUE, !.terminalOwned = TRUE]
 /\ UNCHANGED <<save, read, plan, callers>>
CancelParent ==
 /\ owner.cancelRequested /\ plan[0].actual = "admitted"
 /\ plan' = [plan EXCEPT ![0].actual = "completed"]
 /\ UNCHANGED <<save, read, owner, callers>>
HandOffTerminal ==
 /\ owner.live /\ CanApply /\ owner.known = "post" /\ owner.projection = 2
 /\ owner.handoff = "none" /\ owner.cancelRequested /\ plan[0].accepted
 /\ plan[0].actual = "completed"
 /\ ~owner.unknownRegistration
 /\ plan' = [i \in Sessions |-> IF plan[i].accepted THEN plan[i]
      ELSE [plan[i] EXCEPT !.abandoned = TRUE]]
 /\ owner' = [owner EXCEPT !.handoff = "terminal", !.held = FALSE,
      !.terminalOwned = TRUE, !.mutatedGeneration = owner.generation]
 /\ UNCHANGED <<save, read, callers>>

DeliverReceipt(i) ==
 /\ callers.receipt[i] = "pending" /\ owner.handoff # "none"
 /\ callers' = [callers EXCEPT !.receipt[i] = "done",
      !.execution[i] = IF owner.known = "post" THEN "pending" ELSE "unused"]
 /\ UNCHANGED <<save, read, owner, plan>>
DeliverPendingReceipt(i) ==
 /\ callers.receipt[i] = "pending" /\ owner.handoff = "none"
 /\ callers' = [callers EXCEPT !.receipt[i] = "done"]
 /\ UNCHANGED <<save, read, owner, plan>>
CloseExecution(i) ==
 /\ callers.execution[i] = "pending"
 /\ callers' = [callers EXCEPT !.executionClosed[i] = TRUE,
      !.execution = IF Bug = "shared_observer" THEN
        [j \in Observers |-> IF callers.execution[j] = "pending" THEN "closed" ELSE callers.execution[j]]
        ELSE [callers.execution EXCEPT ![i] = "closed"]]
 /\ UNCHANGED <<save, read, owner, plan>>
CompleteExecution(i) ==
 /\ callers.execution[i] = "pending" /\ plan[0].actual = "completed"
 /\ callers' = [callers EXCEPT !.execution[i] = "complete"]
 /\ UNCHANGED <<save, read, owner, plan>>
ChangeOwner ==
 /\ FaultEnabled("owner_change") /\ owner.generation = 1
 /\ owner' = [owner EXCEPT !.generation = 2]
 /\ UNCHANGED <<save, read, plan, callers>>
Stop ==
 /\ FaultEnabled("shutdown") /\ owner.live
 /\ owner' = [owner EXCEPT !.live = FALSE]
 /\ UNCHANGED <<save, read, plan, callers>>

(* These are deliberately invalid alternatives, not normal protocol actions. *)
ForgetAccepted(i) ==
 /\ Bug = "absent_is_unadmitted"
 /\ owner.handoff = "none" /\ plan[i].actual = "completed" /\ plan[i].accepted
 /\ i \in Children
 /\ plan' = [plan EXCEPT ![i].accepted = FALSE, ![i].actual = "unregistered"]
 /\ UNCHANGED <<save, read, owner, callers>>
RestartPlan ==
 /\ Bug = "restart_plan" /\ owner.handoff = "none"
 /\ plan[0].accepted /\ plan[1].actual = "completed" /\ ~plan[2].accepted
 /\ plan' = [i \in Sessions |-> [plan[i] EXCEPT
      !.accepted = FALSE, !.actual = "unregistered"]]
 /\ UNCHANGED <<save, read, owner, callers>>
UnknownCleanup ==
 /\ Bug = "unknown_cleanup" /\ owner.held
 /\ ~save.handle \/ (~read.handle /\ read.phase # "idle") \/ owner.unknownRegistration
 /\ owner' = [owner EXCEPT !.held = FALSE]
 /\ UNCHANGED <<save, read, plan, callers>>
ReopenOriginal ==
 /\ Bug = "reopen_original" /\ owner.handoff # "none" /\ callers.original = "closed"
 /\ callers' = [callers EXCEPT !.original = "done"]
 /\ UNCHANGED <<save, read, owner, plan>>

Next == SaveEnter \/ SaveRecord \/ SaveQuiet \/ ObserveSaveQuiet \/ LoseSaveHandle
 \/ FreshObservation \/ BeginRead \/ RecordRead \/ ReadQuiet \/ ObserveReadQuiet
 \/ LoseReadHandle \/ ClassifyRead \/ ClassifyRefusal \/ RestoreWait
 \/ InstallRoot \/ InstallExecution \/ PreparePlan \/ InterruptInstall
 \/ (\E i \in Sessions : Register(i) \/ RejectRegistration(i) \/ LoseRegistrationResponse(i))
 \/ (\E i \in Children : FinishChild(i) \/ ForgetAccepted(i))
 \/ FinishParent \/ HandOffContinuation \/ Cancel \/ ProcessRestoredCancellation
 \/ CancelParent \/ HandOffTerminal \/ RestartPlan \/ ChangeOwner \/ Stop \/ UnknownCleanup \/ ReopenOriginal
 \/ (\E i \in ActiveObservers : NamedObservation(i) \/ CloseReceipt(i) \/ DeliverReceipt(i)
      \/ DeliverPendingReceipt(i) \/ CloseExecution(i) \/ CompleteExecution(i))

Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(SaveEnter) /\ WF_vars(SaveRecord) /\ WF_vars(SaveQuiet)
 /\ WF_vars(ObserveSaveQuiet) /\ WF_vars(FreshObservation) /\ WF_vars(BeginRead)
 /\ WF_vars(RecordRead) /\ WF_vars(ReadQuiet) /\ WF_vars(ObserveReadQuiet)
 /\ WF_vars(ClassifyRead) /\ WF_vars(ClassifyRefusal) /\ WF_vars(RestoreWait)
 /\ WF_vars(InstallRoot) /\ WF_vars(InstallExecution) /\ WF_vars(PreparePlan)
 /\ WF_vars(HandOffContinuation) /\ WF_vars(HandOffTerminal)
 /\ WF_vars(ProcessRestoredCancellation) /\ WF_vars(CancelParent)
 /\ \A i \in Sessions : WF_vars(Register(i)) /\ WF_vars(RejectRegistration(i))
      /\ WF_vars(LoseRegistrationResponse(i))

TypeOK ==
 /\ save.handle \in BOOLEAN /\ save.physical \in BOOLEAN /\ save.completeProof \in BOOLEAN
 /\ read.handle \in BOOLEAN /\ read.physical \in BOOLEAN
 /\ read.disposition \in {"unknown", "pre", "post"}
 /\ owner.held \in BOOLEAN /\ owner.live \in BOOLEAN /\ owner.wanted \in BOOLEAN
 /\ owner.prepared \in BOOLEAN /\ owner.cancelRequested \in BOOLEAN
 /\ owner.cancelBound \in BOOLEAN /\ owner.cancelProcessed \in BOOLEAN
 /\ owner.terminalOwned \in BOOLEAN /\ owner.faultSpent \in BOOLEAN
 /\ owner.unknownRegistration \in BOOLEAN
 /\ save.phase \in {"refused", "queued", "running", "recorded", "quiet"}
 /\ read.phase \in {"idle", "running", "recorded", "quiet"} /\ read.starts \in 0..2
 /\ owner.known \in {"unknown", "pre", "post"} /\ owner.projection \in 0..2
 /\ owner.handoff \in {"none", "wait", "sessions", "terminal"}
 /\ owner.generation \in 1..2 /\ owner.mutatedGeneration \in 0..2
 /\ callers.original \in {"closed", "done"}
 /\ \A i \in Sessions : plan[i].actual \in {"unregistered", "admitted", "completed"}
      /\ plan[i].admittedCount \in 0..2 /\ plan[i].effects \in 0..2
      /\ plan[i].accepted \in BOOLEAN /\ plan[i].abandoned \in BOOLEAN
 /\ \A i \in Observers : callers.receipt[i] \in {"unused", "pending", "closed", "done"}
      /\ callers.execution[i] \in {"unused", "pending", "closed", "complete"}
      /\ callers.receiptClosed[i] \in BOOLEAN /\ callers.executionClosed[i] \in BOOLEAN
CompleteEvidence == owner.known = "post" => Outcome = "post"
PreEvidence == owner.known = "pre" => Outcome \in {"pre", "refused"}
PhysicalBeforeApplication == owner.projection > 0 =>
 save.physical /\ read.phase = "idle"
ExactOwnerMutation == owner.mutatedGeneration \in {0, 1}
SingleRegistration == \A i \in Sessions : plan[i].admittedCount <= 1
NoEffectReplay == \A i \in Children : plan[i].effects <= 1
DecisionAuthority == \A i \in Children : plan[i].effects > 0 => Approved /\ Outcome = "post"
WaitCancellationConnected == owner.handoff = "wait" => owner.cancelBound
ContinuationComplete == owner.handoff = "sessions" => \A i \in Sessions : plan[i].accepted
TerminalTransferComplete == owner.handoff = "terminal" => owner.terminalOwned /\
 plan[0].actual = "completed" /\
 ~owner.unknownRegistration /\ (\A i \in Sessions : plan[i].accepted \/ plan[i].abandoned)
CustodyUntilHandoff == ~owner.held => owner.handoff # "none"
UnknownCustody == (~save.handle /\ ~save.physical) \/
 (~read.handle /\ read.phase # "idle" /\ ~read.physical) \/ owner.unknownRegistration => owner.held
ClosedOriginalStaysClosed == callers.original = "closed"
ClosedObserversStayClosed == \A i \in Observers :
 (callers.receiptClosed[i] => callers.receipt[i] = "closed") /\
 (callers.executionClosed[i] => callers.execution[i] = "closed")
IndependentObservers == \A i \in Observers : callers.execution[i] = "closed" => callers.executionClosed[i]
RestoredCancellationEventuallyHandled ==
 []((owner.handoff = "wait" /\ owner.cancelRequested) => <> owner.cancelProcessed)
EventuallyResolved == <> (owner.handoff # "none")

NoRestoredCancellationWitness == ~(owner.handoff = "wait" /\ owner.cancelProcessed)
NoPreRestoreWitness == ~(owner.handoff = "wait" /\ owner.cancelBound)
NoPartialPlanWitness == ~(plan[0].accepted /\ plan[1].accepted /\ ~plan[2].accepted /\ owner.held)
NoTerminalHandoffWitness == ~(owner.handoff = "terminal" /\ \E i \in Children : plan[i].abandoned)
NoLateUnknownWitness == ~(save.phase = "quiet" /\ ~save.handle /\ ~save.physical /\ owner.held)
NoIndependentCompletionWitness == ~(callers.execution[1] = "closed" /\ callers.execution[2] = "complete")
=============================================================================
