-------------------- MODULE NativeParentOutcomeRecovery --------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Kind, Save, ChildKind, ChildState, InitialHold, Approved,
          Readable, Caller, ExplicitRetry, Cleanup, Publication, StableRead,
          RefuseFirst, RetryReplyLost, InitiallyCaptured, NoWriteStarted,
          Drift, ObserveClients, Bug
VARIABLES durable, child, owner, work, clients, originalPhysical
vars == <<durable, child, owner, work, clients, originalPhysical>>
OutcomeKinds == {"terminal", "coordination_wait", "approval_wait"}
Fields == {"root", "execution", "journal", "extension", "cancellation", "holds"}
Before == [root |-> 0, execution |-> 0, journal |-> 0,
           extension |-> 0, cancellation |-> 0, holds |-> InitialHold]
After == [root |-> IF Kind = "coordination_wait" THEN 0 ELSE 1,
          execution |-> 1, journal |-> IF Kind = "terminal" THEN 1 ELSE 0,
          extension |-> IF Kind = "decision" THEN 0 ELSE 1,
          cancellation |-> 0, holds |-> IF Kind = "decision" THEN InitialHold ELSE 1]
AgentBlobAfter == IF Kind = "coordination_wait" THEN 0 ELSE 1
NativeBlobAfter == IF Kind = "decision" THEN 0 ELSE 1
Observers == 1..2
InitialChild == [root |-> ChildState # "absent" /\ ChildState # "execution_only",
  execution |-> ChildState # "absent" /\ ChildState # "root_only",
  status |-> ChildState, reservation |-> 1, definition |-> 1, hold |-> TRUE,
  outcome |-> 1, generation |-> 1, changed |-> FALSE]
Absent == ~child.root /\ ~child.execution
Related == child.root /\ child.execution /\ child.reservation = 1 /\
           child.definition = 1 /\ child.hold
Terminal == Related /\ child.status = "terminal"
AckExact == ChildKind # "ack" \/ child.outcome = 1
OutcomeAuthority == IF ChildKind = "unimported"
  THEN Absent \/ (Related /\ child.status \in {"active", "suspended", "terminal"})
  ELSE Terminal /\ AckExact
DecisionAuthority == IF ChildKind = "unimported" THEN Absent \/ Terminal
                     ELSE Terminal /\ AckExact
Eligible == IF Kind = "decision" THEN DecisionAuthority ELSE OutcomeAuthority
Grant == IF Bug = "ignore_child_authority" THEN TRUE
         ELSE IF Bug = "freeze_child_generation" THEN Eligible /\ child.generation = 1
         ELSE IF Bug = "freeze_child_status" THEN Eligible /\ child.status = ChildState
         ELSE IF Bug = "ignore_ack" /\ ChildKind = "ack" THEN Terminal
         ELSE IF Bug = "ignore_child_hold" THEN
           (IF ChildKind = "unimported" THEN Absent ELSE FALSE) \/
           (child.root /\ child.execution /\ child.reservation = 1 /\
            child.definition = 1 /\ child.status = "terminal" /\ AckExact)
         ELSE Eligible
Equal(row, expected) ==
  IF Bug \in Fields THEN [row EXCEPT ![Bug] = expected[Bug]] = expected
  ELSE row = expected
ContentExact == durable.agentBlob = AgentBlobAfter /\ durable.nativeBlob = NativeBlobAfter
ContentCheck == (durable.agentBlob = AgentBlobAfter \/ Bug = "agent_blob") /\
                (durable.nativeBlob = NativeBlobAfter \/ Bug = "native_blob")
ExactPost == durable.row = After /\ ContentExact
Fact == IF ~Readable THEN "unknown"
        ELSE IF Equal(durable.row, After) /\ ContentCheck THEN "post"
        ELSE IF Equal(durable.row, Before) THEN "pre" ELSE "unknown"

Init ==
 /\ durable = [row |-> IF Save = "post" THEN After ELSE Before,
       agentBlob |-> IF Save = "post" THEN AgentBlobAfter ELSE 0,
       nativeBlob |-> IF Save = "post" THEN NativeBlobAfter ELSE 0,
       changed |-> FALSE, writes |-> 0, validWrites |-> TRUE,
       childWrites |-> 0, historyHeld |-> TRUE]
 /\ child = InitialChild
 /\ owner = [held |-> TRUE, original |-> TRUE, known |-> "unknown",
       everPost |-> FALSE, exactHistory |-> TRUE, evidence |-> InitiallyCaptured,
       validDeferred |-> TRUE, ready |-> FALSE, applied |-> FALSE,
       application |-> "none", publicationCount |-> 0, identity |-> 0,
       executionAdmitted |-> TRUE, executionState |-> "uncertain",
       cancellationBound |-> FALSE, coordinationHandle |-> FALSE,
       receiptKind |-> "none", receiptExecution |-> FALSE, receiptApproval |-> FALSE,
       decisionAdmissions |-> 0, validDecision |-> TRUE, validApplication |-> TRUE,
       preparations |-> 1, participantRuns |-> 1, effects |-> 0]
 /\ work = [stage |-> "idle", count |-> 0, kind |-> "read", result |-> "unknown",
       physical |-> TRUE, grant |-> FALSE, exactFact |-> FALSE, validCapture |-> TRUE]
 /\ clients = [original |-> "failed", status |-> [i \in Observers |-> "unused"],
       cancelled |-> {}, validRelease |-> TRUE]
 /\ originalPhysical = FALSE

OriginalCompletes ==
 /\ Cleanup /\ ~originalPhysical
 /\ originalPhysical' = TRUE
 /\ UNCHANGED <<durable, child, owner, work, clients>>

BeginAttempt ==
 /\ Caller /\ owner.held /\ ~owner.applied /\ ~owner.ready
 /\ owner.original \/ Bug = "stale_owner"
 /\ originalPhysical \/ Bug = "ignore_physical"
 /\ work.stage = "idle" /\ work.count < 3
 /\ work' = [work EXCEPT !.stage = "running", !.count = @ + 1,
       !.kind = IF owner.known = "pre" /\ ExplicitRetry /\ Kind # "decision"
                 THEN "retry" ELSE "read",
       !.physical = FALSE, !.grant = FALSE, !.exactFact = FALSE]
 /\ clients' = IF ObserveClients THEN [clients EXCEPT
       !.status = [i \in Observers |-> IF clients.status[i] = "unused"
                    THEN "pending" ELSE clients.status[i]]] ELSE clients
 /\ UNCHANGED <<durable, child, owner, originalPhysical>>

GuardedTransaction ==
 /\ work.stage = "running"
 /\ LET deferred == ~owner.evidence /\ Kind = "decision"
        captureOK == ~deferred \/
          ((NoWriteStarted \/ Bug = "unproved_capture") /\ Readable /\ durable.row = Before)
        fact == IF ~captureOK \/ (~owner.evidence /\ ~deferred /\ Bug # "invent_outcome_proof")
                THEN "unknown"
                ELSE IF Bug = "cached_pre" /\ work.kind = "retry" THEN "pre" ELSE Fact
        needGrant == Kind = "decision" \/ fact = "pre"
        grant == ~needGrant \/ Grant
        write == fact = "pre" /\
          ((work.kind = "retry" /\ grant) \/ (Bug = "retry_decision" /\ Kind = "decision") \/
           (work.kind = "retry" /\ Bug = "skip_retry_authority"))
        row == IF write THEN IF Bug = "omit_hold" THEN [After EXCEPT !.holds = InitialHold]
                             ELSE After ELSE durable.row
        agentBlob == IF write /\ Bug # "omit_agent_blob" THEN AgentBlobAfter ELSE durable.agentBlob
        nativeBlob == IF write /\ Bug # "omit_native_blob" THEN NativeBlobAfter ELSE durable.nativeBlob
        post == IF write THEN "post" ELSE fact
        result == IF write /\ RetryReplyLost THEN "unknown" ELSE post
        exact == IF write THEN row = After /\ agentBlob = AgentBlobAfter /\ nativeBlob = NativeBlobAfter
                 ELSE IF fact = "post" THEN ExactPost ELSE durable.row = Before
    IN /\ durable' = [durable EXCEPT !.row = row, !.agentBlob = agentBlob,
           !.nativeBlob = nativeBlob, !.writes = @ + IF write THEN 1 ELSE 0,
           !.validWrites = @ /\ (~write \/ (Kind # "decision" /\ durable.row = Before /\
             Eligible /\ originalPhysical /\ owner.original /\ row = After /\
             agentBlob = AgentBlobAfter /\ nativeBlob = NativeBlobAfter)),
           !.childWrites = @ + IF write /\ Bug = "rewrite_child" THEN 1 ELSE 0,
           !.historyHeld = @ /\ ~(write /\ Bug = "drop_history")]
       /\ work' = [work EXCEPT !.stage = "recorded", !.result = result,
           !.grant = grant, !.exactFact = exact,
           !.validCapture = ~deferred \/ (NoWriteStarted /\ Readable /\ durable.row = Before)]
       /\ owner' = [owner EXCEPT !.evidence = @ \/ (deferred /\ captureOK),
           !.validDeferred = @ /\ (~deferred \/ ~captureOK \/ NoWriteStarted),
           !.preparations = @ + IF write /\ Bug = "rebuild_preparation" THEN 1 ELSE 0,
           !.participantRuns = @ + IF write /\ Bug = "replay_participant" THEN 1 ELSE 0,
           !.effects = @ + IF write /\ Bug = "replay_effect" THEN 1 ELSE 0]
 /\ UNCHANGED <<child, clients, originalPhysical>>

WorkerCompletes ==
 /\ Cleanup /\ work.stage = "recorded" /\ ~work.physical
 /\ work' = [work EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<durable, child, owner, clients, originalPhysical>>

ReceiveAttempt ==
 /\ work.stage = "recorded" /\ (work.physical \/ Bug = "ignore_physical")
 /\ owner.original \/ Bug = "stale_owner"
 /\ owner' = [owner EXCEPT
       !.known = IF @ = "post" /\ Bug # "forget_post" THEN @ ELSE work.result,
       !.everPost = @ \/ work.result = "post",
       !.exactHistory = @ /\ (work.result # "post" \/ work.exactFact),
       !.ready = (IF Kind = "decision" THEN work.result \in {"pre", "post"} /\ work.grant
                   ELSE work.result = "post") /\ ~(RefuseFirst /\ work.count = 1)]
 /\ work' = [work EXCEPT !.stage = "idle"]
 /\ clients' = [clients EXCEPT
       !.status = [i \in Observers |-> IF clients.status[i] = "pending" THEN "complete"
                                      ELSE clients.status[i]],
       !.original = IF Bug = "reopen_original" /\ work.result = "post" THEN "complete" ELSE @]
 /\ UNCHANGED <<durable, child, originalPhysical>>

(* Outcome publication applies an already established fact. It grants no new
   business admission. Approval decisions instead need fresh current authority. *)
PermitCachedApplication ==
 /\ owner.held /\ ~owner.applied /\ ~owner.ready /\ owner.known = "post"
 /\ Kind # "decision" \/ Bug = "cached_decision_post"
 /\ work.stage = "idle"
 /\ owner' = [owner EXCEPT !.ready = TRUE]
 /\ UNCHANGED <<durable, child, work, clients, originalPhysical>>

ApplyPublication ==
 /\ Publication /\ owner.held /\ owner.publicationCount < 2
 /\ (~owner.applied \/ Bug = "repeat_publication")
 /\ owner.ready \/ (Bug = "repeat_publication" /\ owner.applied)
 /\ work.stage = "idle" /\ (work.physical \/ Bug = "ignore_physical")
 /\ originalPhysical \/ Bug = "ignore_physical"
 /\ owner.original \/ Bug = "stale_owner"
 /\ LET selected == IF Kind = "decision" THEN
                      IF owner.known = "pre" THEN "approval_restored" ELSE "decision_continuation"
                    ELSE Kind
        applied == IF Bug = "all_terminal" THEN "terminal" ELSE selected
        suspended == applied \in {"approval_wait", "approval_restored"}
        decision == selected = "decision_continuation"
    IN /\ owner' = [owner EXCEPT !.applied = TRUE, !.ready = FALSE,
           !.application = applied, !.publicationCount = @ + 1,
           !.identity = IF Bug = "wrong_identity" THEN 2 ELSE 1,
           !.executionAdmitted = IF Bug = "release_suspended_execution" /\ suspended THEN FALSE
                                 ELSE applied \in {"approval_wait", "approval_restored", "decision_continuation"},
           !.executionState = CASE applied = "terminal" -> "terminal"
                              [] applied = "coordination_wait" -> "active"
                              [] suspended -> "suspended" [] OTHER -> "active",
           !.cancellationBound = suspended /\ Bug # "drop_wait_cancellation",
           !.coordinationHandle = applied = "coordination_wait" /\ Bug # "omit_coordination_handle",
           !.receiptKind = IF Kind \in OutcomeKinds THEN applied ELSE "none",
           !.receiptExecution = (Kind \in OutcomeKinds /\ applied = "terminal") \/ Bug = "wait_as_execution",
           !.receiptApproval = Kind \in OutcomeKinds /\ applied = "approval_wait",
           !.decisionAdmissions = @ + IF decision THEN 1 ELSE 0,
           !.validDecision = @ /\ (Kind # "decision" \/
             (DecisionAuthority /\ owner.original /\ work.exactFact /\
              (IF owner.known = "post" THEN ExactPost ELSE durable.row = Before))),
           !.validApplication = @ /\ (owner.original /\ originalPhysical /\ work.physical),
           !.effects = @ + IF (decision /\ Approved) \/
             (Bug = "run_wait_tool" /\ applied = "approval_wait") THEN 1 ELSE 0]
 /\ UNCHANGED <<durable, child, work, clients, originalPhysical>>

ReleaseRecovery ==
 /\ owner.held /\ owner.applied /\ work.stage = "idle" /\ work.physical /\ originalPhysical
 /\ owner' = [owner EXCEPT !.held = FALSE]
 /\ UNCHANGED <<durable, child, work, clients, originalPhysical>>

CancelObserver(i) ==
 /\ ObserveClients /\ i \in Observers /\ clients.status[i] = "pending"
 /\ clients' = [clients EXCEPT !.status[i] = "cancelled", !.cancelled = @ \cup {i},
       !.validRelease = @ /\ Bug # "observer_releases_owner"]
 /\ owner' = IF Bug = "observer_releases_owner" THEN [owner EXCEPT !.held = FALSE] ELSE owner
 /\ UNCHANGED <<durable, child, work, originalPhysical>>

MayDrift == ~StableRead \/ Kind # "decision" \/
            (work.stage # "recorded" /\ ~owner.ready)
ChangeParent ==
 /\ Drift \in Fields \cup {"agent_blob", "native_blob"} /\ ~durable.changed
 /\ MayDrift /\ ~owner.applied
 /\ durable' = [durable EXCEPT !.row = IF Drift \in Fields THEN [@ EXCEPT ![Drift] = 2] ELSE @,
       !.agentBlob = IF Drift = "agent_blob" THEN 2 ELSE @,
       !.nativeBlob = IF Drift = "native_blob" THEN 2 ELSE @, !.changed = TRUE]
 /\ UNCHANGED <<child, owner, work, clients, originalPhysical>>
ChangeChild ==
 /\ Drift \in {"child_root", "child_reservation", "child_definition", "child_hold",
               "child_active", "child_suspended", "child_progress", "child_generation", "child_outcome"}
 /\ ~child.changed /\ MayDrift /\ ~owner.applied
 /\ child' = [child EXCEPT !.root = IF Drift = "child_root" THEN TRUE ELSE @,
       !.reservation = IF Drift = "child_reservation" THEN 2 ELSE @,
       !.definition = IF Drift = "child_definition" THEN 2 ELSE @,
       !.hold = IF Drift = "child_hold" THEN FALSE ELSE @,
       !.status = CASE Drift = "child_active" -> "active"
                 [] Drift = "child_suspended" -> "suspended"
                 [] Drift = "child_progress" -> "terminal" [] OTHER -> @,
       !.generation = IF Drift = "child_generation" THEN 2 ELSE @,
       !.outcome = IF Drift = "child_outcome" THEN 2 ELSE @, !.changed = TRUE]
 /\ UNCHANGED <<durable, owner, work, clients, originalPhysical>>
ReplaceOwner ==
 /\ Drift = "owner" /\ owner.original /\ ~owner.applied /\ work.stage = "idle"
 /\ owner' = [owner EXCEPT !.original = FALSE]
 /\ UNCHANGED <<durable, child, work, clients, originalPhysical>>

Next == OriginalCompletes \/ BeginAttempt \/ GuardedTransaction \/ WorkerCompletes \/
        ReceiveAttempt \/ PermitCachedApplication \/ ApplyPublication \/ ReleaseRecovery \/
        (\E i \in Observers : CancelObserver(i)) \/ ChangeParent \/ ChangeChild \/ ReplaceOwner
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(OriginalCompletes) /\ WF_vars(BeginAttempt) /\
  WF_vars(GuardedTransaction) /\ WF_vars(WorkerCompletes) /\ WF_vars(ReceiveAttempt) /\
  WF_vars(PermitCachedApplication) /\ WF_vars(ApplyPublication) /\ WF_vars(ReleaseRecovery)

TypeOK == /\ owner.known \in {"unknown", "pre", "post"}
          /\ work.stage \in {"idle", "running", "recorded"} /\ work.count \in 0..3
          /\ owner.publicationCount \in 0..1 /\ owner.decisionAdmissions \in 0..1
ExactRetry == durable.validWrites
ExactHistoricalProof == owner.exactHistory
HistoricalPostSticky == owner.everPost => owner.known = "post"
DeferredReadOnlyProof == owner.validDeferred /\ (Kind # "decision" \/ durable.writes = 0)
FreshDecisionAuthority == owner.validDecision
SeparateSavedKind == owner.applied =>
  (IF Kind = "decision" THEN owner.application \in {"approval_restored", "decision_continuation"}
   ELSE owner.application = Kind)
ExactPublicationIdentity == owner.applied => owner.identity = 1
OnePublication == owner.publicationCount <= 1
EvidenceBeforeApplication == owner.applied => owner.evidence /\
  (InitiallyCaptured \/ (Kind = "decision" /\ NoWriteStarted))
OutcomeReceiptMeaning == (owner.applied /\ Kind \in OutcomeKinds) =>
  owner.receiptKind = Kind /\ (owner.receiptExecution = (Kind = "terminal")) /\
  (owner.receiptApproval = (Kind = "approval_wait"))
WaitLifetime == owner.applied =>
  (owner.application \in {"approval_wait", "approval_restored"} =>
    owner.executionAdmitted /\ owner.executionState = "suspended" /\ owner.cancellationBound) /\
  (owner.application = "coordination_wait" => ~owner.executionAdmitted /\
    owner.executionState = "active" /\ owner.coordinationHandle) /\
  (owner.application = "terminal" => ~owner.executionAdmitted /\ owner.executionState = "terminal")
NoProtectedWaitEffect == Kind \in OutcomeKinds => owner.effects = 0
NoBusinessReplay == owner.preparations = 1 /\ owner.participantRuns = 1 /\
  owner.effects = IF Kind = "decision" /\ Approved THEN owner.decisionAdmissions ELSE 0
IndependentChildDomain == durable.childWrites = 0
HistoryRetained == durable.historyHeld
PhysicalCustody == clients.validRelease /\ owner.validApplication /\
  (work.stage # "idle" => owner.held)
ClosedOriginal == clients.original = "failed"
IndependentObservers == \A i \in clients.cancelled : clients.status[i] = "cancelled"
EventuallyApplied == <>owner.applied
EventuallyReleased == <>~owner.held

NoCoordinationWaitWitness == ~(owner.applied /\ owner.application = "coordination_wait" /\
  owner.executionState = "active" /\ ~owner.executionAdmitted /\ owner.coordinationHandle)
NoApprovalWaitWitness == ~(owner.applied /\ owner.application = "approval_wait" /\
  owner.executionState = "suspended" /\ owner.executionAdmitted /\ owner.cancellationBound)
NoRestoredDecisionWitness == ~(owner.applied /\ owner.application = "approval_restored" /\ durable.writes = 0)
NoPostBlockedWitness == ~(owner.known = "post" /\ ~owner.ready /\ ~DecisionAuthority /\
  owner.held /\ ~owner.applied /\ work.stage = "idle")
NoCancelledPhysicalWitness == ~(clients.cancelled # {} /\ work.stage = "recorded" /\
  ~work.physical /\ owner.held)
NoIndependentObserversWitness == ~(clients.status[1] = "cancelled" /\ clients.status[2] = "complete")
NoLegalChildProgressWitness == ~(child.status = "terminal" /\ child.changed /\ owner.applied)
NoDeferredPreWitness == ~(~InitiallyCaptured /\ owner.evidence /\ owner.application = "approval_restored")
=============================================================================
