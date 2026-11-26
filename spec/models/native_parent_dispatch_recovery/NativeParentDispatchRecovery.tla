-------------------- MODULE NativeParentDispatchRecovery --------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Save, ChildKind, ChildState, Readable, Caller, ExplicitRetry,
          Cleanup, Admission, StableRead, RefuseFirst, RetryReplyLost,
          Drift, ObserveClients, Bug
VARIABLES durable, child, owner, work, clients, originalPhysical
vars == <<durable, child, owner, work, clients, originalPhysical>>
Fields == {"root", "execution", "journal", "extension", "cancellation", "holds"}
Before == [root |-> 0, execution |-> 0, journal |-> 0,
           extension |-> 0, cancellation |-> 0,
           holds |-> IF ChildKind = "new" THEN 0 ELSE 1]
After == [root |-> 0, execution |-> 1, journal |-> 0,
          extension |-> 1, cancellation |-> 0, holds |-> 1]
Observers == 1..2
InitialChild == [
  root |-> ChildState # "absent" /\ ChildState # "execution_only",
  execution |-> ChildState # "absent" /\ ChildState # "root_only",
  status |-> ChildState, reservation |-> 1, definition |-> 1, hold |-> TRUE,
  generation |-> 1, changed |-> FALSE]

(* The extension coordinate is its decoded opaque content, not just its ref. *)
ObservedParent == IF durable.row.extension = 1 /\ durable.blob # 1
                  THEN [durable.row EXCEPT !.extension = 2] ELSE durable.row
Equal(row, expected) ==
  IF Bug \in Fields THEN [row EXCEPT ![Bug] = expected[Bug]] = expected
  ELSE row = expected
Fact == IF ~Readable THEN "unknown"
        ELSE IF Equal(ObservedParent, After) THEN "post"
        ELSE IF Equal(ObservedParent, Before) THEN "pre" ELSE "unknown"
Absent == ~child.root /\ ~child.execution
Terminal == child.root /\ child.execution /\ child.status = "terminal" /\
            child.reservation = 1 /\ child.definition = 1 /\ child.hold
Eligible == IF ChildKind = "new" THEN Absent
            ELSE IF ChildKind = "imported" THEN Terminal
            ELSE Absent \/ Terminal
Grant == IF Bug = "freeze_child_generation" THEN Eligible /\ child.generation = 1
         ELSE IF Bug = "accept_active_child" THEN TRUE
         ELSE IF Bug = "ignore_child_hold" /\ child.status = "terminal"
           THEN child.root /\ child.execution /\ child.reservation = 1 /\ child.definition = 1
         ELSE IF Bug = "ignore_child_reservation" /\ child.status = "terminal"
           THEN child.root /\ child.execution /\ child.definition = 1 /\ child.hold
         ELSE IF Bug = "ignore_child_definition" /\ child.status = "terminal"
           THEN child.root /\ child.execution /\ child.reservation = 1 /\ child.hold
         ELSE IF Bug = "new_root_only" /\ ChildKind = "new"
           THEN ~child.execution
         ELSE IF Bug = "imported_absent" /\ ChildKind = "imported"
           THEN Absent \/ Terminal
         ELSE Eligible

Init ==
 /\ durable = [row |-> IF Save = "post" THEN After ELSE Before,
       blob |-> IF Save = "post" THEN 1 ELSE 0,
       changed |-> FALSE, writes |-> 0, validWrites |-> TRUE,
       childWrites |-> 0, historyHeld |-> TRUE]
 /\ child = InitialChild
 /\ owner = [held |-> TRUE, known |-> "unknown", everPost |-> FALSE,
       fresh |-> FALSE, admitted |-> FALSE, admissions |-> 0,
       validAdmission |-> TRUE, exactProof |-> TRUE, physicalAdmission |-> TRUE,
       originalGeneration |-> TRUE, preparations |-> 1, participantRuns |-> 1,
       effects |-> 0, pending |-> TRUE]
 /\ work = [stage |-> "idle", count |-> 0, kind |-> "read",
       result |-> "unknown", physical |-> TRUE, grant |-> FALSE,
       exactProof |-> FALSE, authorityAtRead |-> FALSE]
 /\ clients = [original |-> "failed",
       status |-> [i \in Observers |-> "unused"],
       cancelled |-> {}, validRelease |-> TRUE]
 /\ originalPhysical = FALSE

OriginalCompletes ==
 /\ Cleanup /\ ~originalPhysical
 /\ originalPhysical' = TRUE
 /\ UNCHANGED <<durable, child, owner, work, clients>>

BeginAttempt ==
 /\ Caller /\ owner.held /\ owner.pending /\ ~owner.fresh
 /\ owner.originalGeneration \/ Bug = "stale_owner"
 /\ originalPhysical \/ Bug = "ignore_physical"
 /\ work.stage = "idle" /\ work.count < 3
 /\ work' = [work EXCEPT !.stage = "running", !.count = @ + 1,
       !.kind = IF owner.known = "pre" /\ ExplicitRetry THEN "retry" ELSE "read",
       !.physical = FALSE, !.grant = FALSE, !.exactProof = FALSE]
 /\ clients' = IF ObserveClients
       THEN [clients EXCEPT !.status = [i \in Observers |->
         IF clients.status[i] = "unused" THEN "pending" ELSE clients.status[i]]]
       ELSE clients
 /\ UNCHANGED <<durable, child, owner, originalPhysical>>

GuardedTransaction ==
 /\ work.stage = "running"
 /\ LET fact == IF Bug = "cached_post" /\ owner.known = "post" THEN "post"
                ELSE IF Bug = "cached_pre" /\ work.kind = "retry" THEN "pre"
                ELSE Fact
        grant == IF Bug = "cached_post" /\ owner.known = "post" THEN TRUE ELSE Grant
        write == work.kind = "retry" /\ fact = "pre" /\
                 (grant \/ Bug = "skip_retry_authority")
        row == IF write THEN
                 IF Bug = "omit_hold" THEN [After EXCEPT !.holds = 0] ELSE After
               ELSE durable.row
        blob == IF write /\ Bug # "omit_content" THEN 1 ELSE durable.blob
        post == IF write THEN "post" ELSE fact
        result == IF write /\ RetryReplyLost THEN "unknown" ELSE post
    IN /\ durable' = [durable EXCEPT !.row = row, !.blob = blob,
           !.writes = @ + IF write THEN 1 ELSE 0,
           !.validWrites = @ /\ (~write \/
              (ObservedParent = Before /\ Eligible /\ originalPhysical /\
               owner.originalGeneration /\ row = After /\ blob = 1)),
           !.childWrites = @ + IF write /\ Bug = "rewrite_child" THEN 1 ELSE 0,
           !.historyHeld = @ /\ ~(write /\ Bug = "drop_history")]
       /\ work' = [work EXCEPT !.stage = "recorded", !.result = result,
           !.grant = grant /\ result = "post",
           !.exactProof = IF write THEN row = After /\ blob = 1
                         ELSE ObservedParent = After,
           !.authorityAtRead = Eligible]
       /\ owner' = [owner EXCEPT
           !.preparations = @ + IF write /\ Bug = "rebuild_preparation" THEN 1 ELSE 0,
           !.participantRuns = @ + IF write /\ Bug = "replay_participant" THEN 1 ELSE 0,
           !.effects = @ + IF write /\ Bug = "replay_effect" THEN 1 ELSE 0]
 /\ UNCHANGED <<child, clients, originalPhysical>>

WorkerCompletes ==
 /\ Cleanup /\ work.stage = "recorded" /\ ~work.physical
 /\ work' = [work EXCEPT !.physical = TRUE]
 /\ UNCHANGED <<durable, child, owner, clients, originalPhysical>>

ReceiveAttempt ==
 /\ work.stage = "recorded" /\ work.physical
 /\ owner.originalGeneration \/ Bug = "stale_owner"
 /\ owner' = [owner EXCEPT
       !.known = IF @ = "post" /\ Bug # "forget_post" THEN @ ELSE work.result,
       !.everPost = @ \/ work.result = "post",
       !.fresh = work.result = "post" /\ work.grant /\
                 ~(RefuseFirst /\ work.count = 1)]
 /\ work' = [work EXCEPT !.stage = "idle"]
 /\ clients' = [clients EXCEPT
       !.status = [i \in Observers |-> IF clients.status[i] = "pending"
                      THEN "complete" ELSE clients.status[i]],
       !.original = IF Bug = "reopen_original" /\ work.result = "post"
                      THEN "complete" ELSE @]
 /\ UNCHANGED <<durable, child, originalPhysical>>

AdmitContinuation ==
 /\ Admission /\ owner.held /\ owner.pending /\ owner.fresh
 /\ work.stage = "idle" /\ work.physical
 /\ owner.originalGeneration \/ Bug = "stale_owner"
 /\ originalPhysical \/ Bug = "ignore_physical"
 /\ owner' = [owner EXCEPT !.admitted = TRUE, !.admissions = @ + 1,
       !.pending = FALSE, !.fresh = FALSE,
       !.validAdmission = Eligible /\ owner.originalGeneration,
       !.exactProof = work.exactProof /\ ObservedParent = After,
       !.physicalAdmission = originalPhysical /\ work.physical,
       !.effects = @ + 1]
 /\ UNCHANGED <<durable, child, work, clients, originalPhysical>>

ReleaseOwner ==
 /\ owner.held /\ owner.admitted /\ work.physical /\ originalPhysical
 /\ owner' = [owner EXCEPT !.held = FALSE]
 /\ UNCHANGED <<durable, child, work, clients, originalPhysical>>

CancelObserver(i) ==
 /\ ObserveClients /\ i \in Observers /\ clients.status[i] = "pending"
 /\ clients' = [clients EXCEPT !.status[i] = "cancelled",
       !.cancelled = @ \cup {i},
       !.validRelease = @ /\ Bug # "observer_releases_owner"]
 /\ owner' = IF Bug = "observer_releases_owner"
       THEN [owner EXCEPT !.held = FALSE] ELSE owner
 /\ UNCHANGED <<durable, child, work, originalPhysical>>

(* Guards protect each transaction. StableRead is the separate premise needed
   between its proof and the owner-thread admission; it is not a durable fence. *)
MayDrift == ~StableRead \/
            (work.stage # "recorded" /\ ~owner.fresh)
ChangeParent ==
 /\ Drift \in Fields /\ ~durable.changed /\ MayDrift /\ owner.pending
 /\ durable' = [durable EXCEPT !.row[Drift] = 2, !.changed = TRUE]
 /\ UNCHANGED <<child, owner, work, clients, originalPhysical>>
ChangeChild ==
 /\ Drift \in {"child_root", "child_reservation", "child_hold", "child_active",
               "child_suspended", "child_generation", "child_definition"}
 /\ ~child.changed /\ MayDrift /\ owner.pending
 /\ child' = [child EXCEPT
       !.root = IF Drift = "child_root" THEN TRUE ELSE @,
       !.reservation = IF Drift = "child_reservation" THEN 2 ELSE @,
       !.definition = IF Drift = "child_definition" THEN 2 ELSE @,
       !.hold = IF Drift = "child_hold" THEN FALSE ELSE @,
       !.status = IF Drift = "child_active" THEN "active"
                 ELSE IF Drift = "child_suspended" THEN "suspended" ELSE @,
       !.generation = IF Drift = "child_generation" THEN 2 ELSE @,
       !.changed = TRUE]
 /\ UNCHANGED <<durable, owner, work, clients, originalPhysical>>
ReplaceOwner ==
 /\ Drift = "owner" /\ owner.originalGeneration /\ MayDrift /\ owner.pending
 /\ work.stage = "idle"
 /\ owner' = [owner EXCEPT !.originalGeneration = FALSE]
 /\ UNCHANGED <<durable, child, work, clients, originalPhysical>>

Next == OriginalCompletes \/ BeginAttempt \/ GuardedTransaction \/
        WorkerCompletes \/ ReceiveAttempt \/ AdmitContinuation \/ ReleaseOwner \/
        (\E i \in Observers : CancelObserver(i)) \/
        ChangeParent \/ ChangeChild \/ ReplaceOwner
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(OriginalCompletes) /\ WF_vars(BeginAttempt) /\
  WF_vars(GuardedTransaction) /\ WF_vars(WorkerCompletes) /\
  WF_vars(ReceiveAttempt) /\ WF_vars(AdmitContinuation) /\ WF_vars(ReleaseOwner)

TypeOK == /\ owner.known \in {"unknown", "pre", "post"}
          /\ work.stage \in {"idle", "running", "recorded"}
          /\ work.count \in 0..3 /\ durable.writes \in 0..3
          /\ owner.admissions \in 0..1
          /\ clients.cancelled \subseteq Observers
ExactRetry == durable.validWrites
HistoricalPostSticky == owner.everPost => owner.known = "post"
FreshNativeAuthority == owner.validAdmission
CompleteParentProof == owner.exactProof
IndependentChildDomain == durable.childWrites = 0
NoPreparationOrParticipantReplay == owner.preparations = 1 /\ owner.participantRuns = 1
NoEffectReplay == owner.effects = owner.admissions
HistoryRetained == durable.historyHeld
PhysicalCustody == clients.validRelease /\
  (work.stage # "idle" => owner.held) /\ owner.physicalAdmission
ClosedOriginal == clients.original = "failed"
IndependentObservers == \A i \in clients.cancelled : clients.status[i] = "cancelled"
OneAdmission == owner.admissions <= 1
EventuallyAdmitted == <>owner.admitted
EventuallyReleased == <>~owner.held

NoConfirmedPostBlockedWitness == ~(owner.known = "post" /\ ~owner.fresh /\
  ~Eligible /\ owner.pending /\ owner.held /\ work.stage = "idle")
NoCancelledOwnerWitness == ~(clients.cancelled # {} /\
  work.stage = "recorded" /\ ~work.physical /\ owner.held)
NoIndependentObserversWitness == ~(clients.status[1] = "cancelled" /\
  clients.status[2] = "complete")
NoRetryWitness == ~(durable.writes = 1 /\ owner.admitted)
NoReadOnlyPostWitness == ~(Save = "post" /\ durable.writes = 0 /\ owner.admitted)
NoIrrelevantChildChangeWitness == ~(child.generation = 2 /\ owner.admitted)
=============================================================================
