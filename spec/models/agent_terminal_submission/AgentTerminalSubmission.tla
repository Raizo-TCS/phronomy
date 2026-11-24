------------------------ MODULE AgentTerminalSubmission ------------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Profile, Methods, Fault, FreshCaller, Bug
VARIABLES owner, clients, pool, wire
vars == <<owner, clients, pool, wire>>
Observers == {1, 2}
SubmitSubmit == [i \in Observers |-> "submit"]
SubmitRead == [i \in Observers |-> IF i = 1 THEN "submit" ELSE "read"]
SubmitRetry == [i \in Observers |-> IF i = 1 THEN "submit" ELSE "retry"]
RetryRetry == [i \in Observers |-> "retry"]
ReadSubmit == [i \in Observers |-> IF i = 1 THEN "read" ELSE "submit"]
HasProof == Profile \in {"proof_pre", "proof_post"}
AlreadyBegan == HasProof \/ Profile = "failed_before_proof"
InitiallyQueued == Profile \in {"queued", "unknown"}
InitiallyRejected == Profile \in {"rejected", "blocked"}
FaultEnabled(name) == Fault = "all" \/ Fault = name
Active == {i \in Observers : clients.state[i] = "active"}
Requested == {i \in Observers : clients.state[i] = "requested"}

(* The first caller is already closed. The pool's actual admission and the
   owner's evidence of admission are deliberately different state variables. *)
Init ==
  /\ owner = [admission |-> IF InitiallyRejected THEN "not_admitted"
                            ELSE IF Profile = "unknown" THEN "unknown" ELSE "admitted",
       refusalProof |-> InitiallyRejected, tracked |-> Profile # "unknown" /\ ~InitiallyRejected,
       handleKnown |-> Profile # "unknown" /\ ~InitiallyRejected,
       physicalKnown |-> ~InitiallyQueued, proof |-> HasProof,
       lane |-> IF Profile = "queued" THEN "initial" ELSE IF Profile = "unknown" THEN "unknown" ELSE "idle",
       fact |-> "none", evidencePhysical |-> TRUE,
       custody |-> TRUE, admissionHeld |-> TRUE, applied |-> 0, released |-> FALSE,
       runtime |-> "live", identity |-> TRUE, shutdownClean |-> FALSE,
       callbacks |-> 0, businessRuns |-> 1, submissionCalls |-> 0,
       mixedRejected |-> FALSE, joined |-> FALSE, deniedWithoutProof |-> FALSE,
       unsafeResubmit |-> FALSE, notificationLost |-> FALSE, readWrote |-> FALSE]
  /\ clients = [original |-> "closed_recovery_error",
       state |-> [i \in Observers |-> "unused"], result |-> [i \in Observers |-> "none"]]
  /\ pool = [available |-> Profile # "blocked", restored |-> FALSE,
       accepted |-> IF InitiallyRejected THEN 0 ELSE 1,
       queued |-> IF InitiallyQueued THEN 1 ELSE 0, running |-> 0,
       begun |-> IF AlreadyBegan THEN 1 ELSE 0,
       validations |-> IF AlreadyBegan THEN 1 ELSE 0,
       encodings |-> IF AlreadyBegan THEN 1 ELSE 0,
       step |-> IF AlreadyBegan THEN "completed" ELSE "none",
       durable |-> IF Profile = "proof_post" THEN "post" ELSE "pre",
       writes |-> IF Profile = "proof_post" THEN 1 ELSE 0,
       evidenceActive |-> FALSE]
  /\ wire = FALSE

CanOwn == owner.runtime \in {"live", "draining"} /\ owner.custody /\ ~owner.released
ActualQuiet == pool.queued = 0 /\ pool.running = 0 /\ ~pool.evidenceActive
KnownQuiet == ActualQuiet /\ owner.physicalKnown /\ owner.evidencePhysical
Eligible == owner.admission = "not_admitted" /\ owner.refusalProof /\
            owner.lane = "idle" /\ KnownQuiet
MutantEligible ==
  \/ (Bug = "started_false_is_rejected" /\ pool.begun = 0)
  \/ (Bug = "exception_is_rejected" /\ owner.admission = "unknown")
  \/ (Bug = "begun_failure_is_rejected" /\ ~owner.proof /\ owner.physicalKnown)

Request(i) ==
  /\ i \in Observers /\ clients.state[i] = "unused"
  /\ (~FreshCaller \/ pool.available)
  /\ clients' = [clients EXCEPT !.state[i] = "requested"]
  /\ UNCHANGED <<owner, pool, wire>>

PoolAvailable ==
  /\ ~pool.available /\ ~pool.restored
  /\ pool' = [pool EXCEPT !.available = TRUE, !.restored = TRUE]
  /\ UNCHANGED <<owner, clients, wire>>

(* The right is consumed on acceptance, before the worker can begin. *)
AcceptSubmission(i) ==
  /\ i \in Requested /\ Methods[i] = "submit" /\ CanOwn /\ owner.identity
  /\ pool.available /\ (Eligible \/ MutantEligible)
  /\ owner' = [owner EXCEPT !.admission = IF Bug = "retain_old_refusal" THEN "not_admitted" ELSE "admitted",
       !.refusalProof = Bug = "retain_old_refusal", !.tracked = TRUE, !.handleKnown = TRUE, !.physicalKnown = FALSE,
       !.lane = "submit", !.fact = "none", !.submissionCalls = @ + 1,
       !.unsafeResubmit = @ \/ ~Eligible]
  /\ pool' = [pool EXCEPT !.accepted = @ + 1, !.queued = @ + 1]
  /\ clients' = [clients EXCEPT !.state[i] = "active"]
  /\ wire' = FALSE

(* Only a positive pre-enqueue on_rejected receipt establishes non-admission.
   Neither exception class nor absence of a task handle establishes this fact. *)
RejectWithProof(i) ==
  /\ i \in Requested /\ Methods[i] = "submit" /\ CanOwn /\ Eligible
  /\ ~pool.available
  /\ owner' = [owner EXCEPT !.submissionCalls = @ + 1, !.refusalProof = TRUE]
  /\ clients' = [clients EXCEPT !.state[i] = "done", !.result[i] = "unavailable"]
  /\ UNCHANGED <<pool, wire>>

(* A custom submitter may enqueue and then raise without returning a handle.
   The error could even have the same class as a normal rejection. *)
EnqueueThenUnknownFailure(i) ==
  /\ FaultEnabled("unknown_admission") /\ i \in Requested
  /\ Methods[i] = "submit" /\ CanOwn /\ Eligible /\ pool.available
  /\ owner' = [owner EXCEPT !.admission = "unknown", !.refusalProof = FALSE,
       !.tracked = FALSE, !.handleKnown = FALSE, !.physicalKnown = FALSE,
       !.lane = "unknown", !.submissionCalls = @ + 1]
  /\ pool' = [pool EXCEPT !.accepted = @ + 1, !.queued = @ + 1]
  /\ clients' = [clients EXCEPT !.state[i] = "done", !.result[i] = "unavailable"]
  /\ UNCHANGED wire

(* Deliberately nonconforming backend: the callback claimed no enqueue, but
   the submitter still queued work. This violates the callback contract itself. *)
FalseRefusalReceipt(i) ==
  /\ Bug = "false_refusal_receipt" /\ i \in Requested
  /\ Methods[i] = "submit" /\ CanOwn /\ Eligible /\ pool.available
  /\ owner' = [owner EXCEPT !.submissionCalls = @ + 1]
  /\ pool' = [pool EXCEPT !.accepted = @ + 1, !.queued = @ + 1]
  /\ clients' = [clients EXCEPT !.state[i] = "done", !.result[i] = "unavailable"]
  /\ UNCHANGED wire

Join(i) ==
  /\ i \in Requested /\ CanOwn /\ owner.lane \in {"submit", "read", "retry"}
  /\ Methods[i] = owner.lane
  /\ clients' = [clients EXCEPT !.state[i] = "active"]
  /\ owner' = [owner EXCEPT !.joined = TRUE]
  /\ wire' = (wire \/ KnownQuiet)
  /\ UNCHANGED pool

RejectMixed(i) ==
  /\ i \in Requested /\ CanOwn /\ owner.lane \in {"submit", "read", "retry"}
  /\ Methods[i] # owner.lane
  /\ clients' = [clients EXCEPT !.state[i] = "done", !.result[i] = "unavailable"]
  /\ owner' = [owner EXCEPT !.mixedRejected = TRUE]
  /\ UNCHANGED <<pool, wire>>

DenySubmission(i) ==
  /\ i \in Requested /\ Methods[i] = "submit"
  /\ ~owner.released /\ ~Eligible
  /\ owner.lane # "submit"
  /\ owner' = [owner EXCEPT !.deniedWithoutProof = TRUE]
  /\ clients' = [clients EXCEPT !.state[i] = "done", !.result[i] = "unavailable"]
  /\ UNCHANGED <<pool, wire>>

Unavailable(i) ==
  /\ i \in Requested /\ ~owner.released
  /\ (owner.runtime = "stopped" \/ ~owner.identity \/
       (Methods[i] # "submit" /\ (~owner.proof \/ ~KnownQuiet)))
  /\ clients' = [clients EXCEPT !.state[i] = "done", !.result[i] = "unavailable"]
  /\ UNCHANGED <<owner, pool, wire>>

RepeatReceipt(i) ==
  /\ i \in Requested /\ owner.released
  /\ clients' = [clients EXCEPT !.state[i] = "done", !.result[i] = "confirmed_post"]
  /\ UNCHANGED <<owner, pool, wire>>

BeginWorker ==
  /\ pool.queued > 0 /\ pool.running = 0
  /\ pool' = [pool EXCEPT !.queued = @ - 1, !.running = 1,
       !.begun = @ + 1, !.step = "entered"]
  /\ owner' = [owner EXCEPT !.admission = "admitted", !.refusalProof = FALSE]
  /\ UNCHANGED <<clients, wire>>

Validate ==
  /\ pool.running = 1 /\ pool.step = "entered"
  /\ pool' = [pool EXCEPT !.validations = @ + 1, !.step = "validated"]
  /\ UNCHANGED <<owner, clients, wire>>

Encode ==
  /\ pool.running = 1 /\ pool.step = "validated"
  /\ pool' = [pool EXCEPT !.encodings = @ + 1, !.step = "encoded"]
  /\ UNCHANGED <<owner, clients, wire>>

CaptureProof ==
  /\ pool.running = 1 /\ pool.step = "encoded"
  /\ pool' = [pool EXCEPT !.step = "proof"]
  /\ owner' = [owner EXCEPT !.proof = TRUE]
  /\ UNCHANGED <<clients, wire>>

FailBeforeProof ==
  /\ FaultEnabled("before_proof_failure") /\ pool.running = 1
  /\ pool.step \in {"entered", "validated", "encoded"}
  /\ pool' = [pool EXCEPT !.step = "returned"]
  /\ owner' = [owner EXCEPT !.fact = "unavailable"]
  /\ UNCHANGED <<clients, wire>>

ReturnPost ==
  /\ pool.running = 1 /\ pool.step = "proof"
  /\ pool' = [pool EXCEPT !.step = "returned", !.durable = "post", !.writes = @ + 1]
  /\ owner' = [owner EXCEPT !.fact = "confirmed_post"]
  /\ UNCHANGED <<clients, wire>>

ReturnRollback ==
  /\ FaultEnabled("rollback") /\ pool.running = 1 /\ pool.step = "proof"
  /\ pool' = [pool EXCEPT !.step = "returned"]
  /\ owner' = [owner EXCEPT !.fact = "unavailable"]
  /\ UNCHANGED <<clients, wire>>

FinishPhysical ==
  /\ pool.running = 1 /\ pool.step = "returned"
  /\ pool' = [pool EXCEPT !.running = 0, !.step = "completed"]
  /\ owner' = [owner EXCEPT !.physicalKnown = owner.handleKnown]
  /\ wire' = owner.handleKnown
  /\ UNCHANGED clients

CloseInitial ==
  /\ CanOwn /\ owner.lane = "initial" /\ KnownQuiet
  /\ (wire \/ Requested # {})
  /\ owner' = [owner EXCEPT !.lane = "idle"]
  /\ wire' = FALSE
  /\ UNCHANGED <<clients, pool>>

(* Complete proof selects the separate, already encoded persistence path.
   The submission method itself does not silently become a byte-retry call. *)
StartEvidence(i) ==
  /\ i \in Requested /\ Methods[i] \in {"read", "retry"}
  /\ CanOwn /\ owner.identity /\ owner.proof /\ KnownQuiet /\ owner.lane = "idle"
  /\ owner' = [owner EXCEPT !.lane = Methods[i], !.fact = "none", !.evidencePhysical = FALSE]
  /\ pool' = [pool EXCEPT !.evidenceActive = TRUE]
  /\ clients' = [clients EXCEPT !.state[i] = "active"]
  /\ wire' = FALSE

ComputeEvidence ==
  /\ owner.lane \in {"read", "retry"} /\ owner.fact = "none" /\ pool.evidenceActive
  /\ LET write == owner.lane = "retry" /\ pool.durable = "pre"
     IN /\ owner' = [owner EXCEPT !.fact = IF write \/ pool.durable = "post" THEN "confirmed_post" ELSE "confirmed_pre",
                      !.readWrote = @ \/ (write /\ owner.lane = "read")]
        /\ pool' = [pool EXCEPT !.durable = IF write THEN "post" ELSE @,
             !.writes = @ + IF write THEN 1 ELSE 0,
             !.encodings = @ + IF write /\ Bug = "reencode_byte_retry" THEN 1 ELSE 0]
  /\ UNCHANGED <<clients, wire>>

FinishEvidence ==
  /\ owner.lane \in {"read", "retry"} /\ owner.fact # "none" /\ pool.evidenceActive
  /\ pool' = [pool EXCEPT !.evidenceActive = FALSE]
  /\ owner' = [owner EXCEPT !.evidencePhysical = TRUE]
  /\ wire' = TRUE
  /\ UNCHANGED clients

CancelObserver(i) ==
  /\ FaultEnabled("observer_cancel") /\ i \in Active
  /\ clients' = [clients EXCEPT !.state[i] = "cancelled"]
  /\ owner' = IF Bug = "cancel_drops_slot" THEN [owner EXCEPT !.tracked = FALSE] ELSE owner
  /\ UNCHANGED <<pool, wire>>

LoseNotification ==
  /\ FaultEnabled("notification_loss") /\ wire /\ ~owner.notificationLost
  /\ owner' = [owner EXCEPT !.notificationLost = TRUE]
  /\ clients' = [clients EXCEPT
       !.state = [i \in Observers |-> IF i \in Active THEN "done" ELSE clients.state[i]],
       !.result = [i \in Observers |-> IF i \in Active THEN "unavailable" ELSE clients.result[i]]]
  /\ wire' = FALSE
  /\ UNCHANGED pool

Nudge ==
  /\ CanOwn /\ Requested # {} /\ KnownQuiet /\ ~wire
  /\ owner.lane \in {"initial", "submit", "read", "retry"}
  /\ wire' = TRUE
  /\ UNCHANGED <<owner, clients, pool>>

ApplyPost ==
  /\ CanOwn /\ owner.identity /\ wire /\ KnownQuiet
  /\ owner.lane \in {"submit", "read", "retry"} /\ owner.fact = "confirmed_post"
  /\ owner.applied = 0
  /\ owner' = [owner EXCEPT !.applied = 1,
       !.callbacks = @ + IF Bug = "replay_closed_callback" THEN 1 ELSE 0]
  /\ clients' = IF Bug = "reopen_original" THEN [clients EXCEPT !.original = "result"] ELSE clients
  /\ UNCHANGED <<pool, wire>>

Release ==
  /\ CanOwn /\ owner.identity /\ owner.applied = 1 /\ KnownQuiet
  /\ owner' = [owner EXCEPT !.released = TRUE, !.custody = FALSE, !.admissionHeld = FALSE, !.lane = "idle"]
  /\ clients' = [clients EXCEPT
       !.state = [i \in Observers |-> IF i \in Active THEN "done" ELSE clients.state[i]],
       !.result = [i \in Observers |-> IF i \in Active THEN "confirmed_post" ELSE clients.result[i]]]
  /\ wire' = FALSE
  /\ UNCHANGED pool

CloseUnresolved ==
  /\ CanOwn /\ wire /\ KnownQuiet /\ owner.lane \in {"submit", "read", "retry"}
  /\ owner.fact \in {"unavailable", "confirmed_pre"}
  /\ owner' = [owner EXCEPT !.lane = "idle"]
  /\ clients' = [clients EXCEPT
       !.state = [i \in Observers |-> IF i \in Active THEN "done" ELSE clients.state[i]],
       !.result = [i \in Observers |-> IF i \in Active THEN owner.fact ELSE clients.result[i]]]
  /\ wire' = FALSE
  /\ UNCHANGED pool

ChangeIdentity ==
  /\ FaultEnabled("identity_change") /\ owner.identity /\ ~owner.released
  /\ owner' = [owner EXCEPT !.identity = FALSE]
  /\ UNCHANGED <<clients, pool, wire>>

BeginShutdown ==
  /\ FaultEnabled("shutdown") /\ owner.runtime = "live"
  /\ owner' = [owner EXCEPT !.runtime = "draining"]
  /\ UNCHANGED <<clients, pool, wire>>

StopRuntime ==
  /\ FaultEnabled("shutdown") /\ owner.runtime = "draining"
  /\ owner' = [owner EXCEPT !.runtime = "stopped", !.shutdownClean = owner.released /\ KnownQuiet]
  /\ clients' = [clients EXCEPT
       !.state = [i \in Observers |-> IF i \in Active THEN "done" ELSE clients.state[i]],
       !.result = [i \in Observers |-> IF i \in Active THEN "unavailable" ELSE clients.result[i]]]
  /\ UNCHANGED <<pool, wire>>

Next ==
  \/ \E i \in Observers: Request(i) \/ AcceptSubmission(i) \/ RejectWithProof(i)
       \/ EnqueueThenUnknownFailure(i) \/ FalseRefusalReceipt(i) \/ Join(i) \/ RejectMixed(i) \/ DenySubmission(i)
       \/ Unavailable(i) \/ RepeatReceipt(i) \/ StartEvidence(i) \/ CancelObserver(i)
  \/ PoolAvailable \/ BeginWorker \/ Validate \/ Encode \/ CaptureProof
  \/ FailBeforeProof \/ ReturnPost \/ ReturnRollback \/ FinishPhysical \/ CloseInitial
  \/ ComputeEvidence \/ FinishEvidence \/ LoseNotification \/ Nudge
  \/ ApplyPost \/ Release \/ CloseUnresolved \/ ChangeIdentity \/ BeginShutdown \/ StopRuntime

Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(Request(1)) /\ WF_vars(PoolAvailable)
  /\ WF_vars(AcceptSubmission(1)) /\ WF_vars(BeginWorker) /\ WF_vars(Validate)
  /\ WF_vars(Encode) /\ WF_vars(CaptureProof) /\ WF_vars(ReturnPost) /\ WF_vars(FinishPhysical)
  /\ WF_vars(StartEvidence(1)) /\ WF_vars(ComputeEvidence) /\ WF_vars(FinishEvidence)
  /\ WF_vars(ApplyPost) /\ WF_vars(Release)

TypeOK ==
  /\ owner.admission \in {"not_admitted", "admitted", "unknown"}
  /\ owner.lane \in {"idle", "initial", "unknown", "submit", "read", "retry"}
  /\ owner.fact \in {"none", "unavailable", "confirmed_pre", "confirmed_post"}
  /\ owner.applied \in 0..1 /\ owner.callbacks \in 0..1
  /\ pool.accepted \in 0..3 /\ pool.begun \in 0..3
  /\ pool.validations \in 0..3 /\ pool.encodings \in 0..3
  /\ clients.state \in [Observers -> {"unused", "requested", "active", "done", "cancelled"}]
NonAdmissionNeedsProof == owner.admission = "not_admitted" => owner.refusalProof /\ pool.accepted = 0
RepeatNeedsProvenRefusal == ~owner.unsafeResubmit
AtMostOneAcceptedBlock == pool.accepted <= 1
FirstBlockAtMostOnce == pool.begun <= 1
ValidationAtMostOnce == pool.validations <= 1
EncodingAtMostOnce == pool.encodings <= 1
PhysicalSerialization == pool.queued + pool.running + (IF pool.evidenceActive THEN 1 ELSE 0) <= 1
PhysicalSlotPreserved == owner.handleKnown /\ (pool.queued + pool.running > 0) => owner.tracked
NoOldObserverReplay == clients.original = "closed_recovery_error" /\ owner.callbacks = 0
NoBusinessReplay == owner.businessRuns = 1
ReadNeverWrites == ~owner.readWrote
ReleaseSafe == owner.released => owner.applied = 1 /\ owner.fact = "confirmed_post" /\ KnownQuiet
CustodyUntilRelease == ~owner.released => owner.custody /\ owner.admissionHeld
CleanMeansResolved == owner.shutdownClean => owner.released /\ KnownQuiet

EventuallyReleased == <>owner.released
WitnessNoQueuedDenial == ~(Profile = "queued" /\ pool.begun = 0 /\ owner.deniedWithoutProof /\ pool.accepted = 1)
WitnessNoUnknownDenial == ~(owner.admission = "unknown" /\ owner.deniedWithoutProof /\ pool.accepted = 1)
WitnessNoSubmissionJoin == ~(owner.lane = "submit" /\ owner.joined)
WitnessNoMixedRefusal == ~owner.mixedRejected
WitnessNoFirstRunAfterRefusal == ~(InitiallyRejected /\ pool.begun = 1 /\ pool.encodings = 1 /\ owner.released)
WitnessNoStartedFailureDenial == ~(Profile = "failed_before_proof" /\ owner.deniedWithoutProof /\ pool.begun = 1)
WitnessNoProofUsesBytes == ~(Profile = "proof_pre" /\ owner.released /\ pool.encodings = 1 /\ pool.writes = 1)
WitnessNoCancelIndependent == ~(clients.state[1] = "cancelled" /\ clients.result[2] = "confirmed_post")
WitnessNoStoppedCustody == ~(owner.runtime = "stopped" /\ owner.custody /\ ~owner.shutdownClean)
WitnessNoLostReplyRecovery == ~(owner.notificationLost /\ owner.released)
=============================================================================
