------------------------- MODULE AgentTerminalRecovery -------------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Profile, Modes, Fault, Bug
VARIABLES server, clients, wire
vars == <<server, clients, wire>>
Observers == {1, 2}
ReadRead == [i \in Observers |-> "read"]
RetryRetry == [i \in Observers |-> "retry"]
ReadRetry == [i \in Observers |-> IF i = 1 THEN "read" ELSE "retry"]
StartsPending == Profile \in {"pending", "pending_fresh"}
Facts == {"none", "confirmed_pre", "confirmed_post", "unresolved", "unavailable"}

(* The retained proof already exists. Original observation settlement does not
   complete the accepted job. Detailed records/bytes belong to the adjacent
   AgentTerminalPersistence model, not to this ownership abstraction. *)
Init ==
  /\ server = [runtime |-> "live", owned |-> TRUE, custody |-> TRUE,
       admission |-> TRUE, savePhysical |-> ~StartsPending,
       settled |-> ~StartsPending, authoritative |-> TRUE,
       durable |-> IF Profile = "post" THEN "post" ELSE "pre",
       identity |-> TRUE, lane |-> "idle", laneOrigin |-> "idle",
       lanePhysical |-> TRUE, laneFact |-> "none", lastFact |-> "none",
       physicalCount |-> IF StartsPending THEN 1 ELSE 0,
       applyCount |-> 0, releaseCount |-> 0, callbacks |-> 0,
       businessRuns |-> 1, writes |-> 0, readWrote |-> FALSE,
       overwroteConflict |-> FALSE, unsettledFact |-> FALSE,
       staleApply |-> FALSE, shutdownClean |-> FALSE,
       notificationLost |-> FALSE, interference |-> FALSE,
       readLost |-> FALSE, readRestored |-> FALSE,
       mixedRejected |-> FALSE, joined |-> FALSE]
  /\ clients = [original |-> "recovery_error",
       observation |-> [i \in Observers |-> "unused"],
       result |-> [i \in Observers |-> "none"]]
  /\ wire = [ready |-> FALSE]

FaultEnabled(name) == Fault = "all" \/ Fault = name
ActiveObservers == {i \in Observers : clients.observation[i] = "active"}
RequestedObservers == {i \in Observers : clients.observation[i] = "requested"}
CanOwn == server.runtime \in {"live", "draining"} /\ server.owned /\ server.custody
PhysicalQuiet == server.savePhysical /\ server.physicalCount = 0 /\ server.lanePhysical

(* Backend settlement is independent of local task/worker return. These are
   environment assumptions, not a newly implemented Runtime capability gate. *)
SettleBackend(next) ==
  /\ ~server.settled /\ next \in {"pre", "post"}
  /\ server' = [server EXCEPT !.settled = TRUE, !.durable = next]
  /\ UNCHANGED <<clients, wire>>

FinishOriginalPhysical ==
  /\ ~server.savePhysical
  /\ server' = [server EXCEPT !.savePhysical = TRUE, !.physicalCount = @ - 1]
  /\ UNCHANGED <<clients, wire>>

Request(i) ==
  /\ i \in Observers /\ clients.observation[i] = "unused"
  /\ (Profile # "pending_fresh" \/ (server.savePhysical /\ server.settled))
  /\ clients' = [clients EXCEPT !.observation[i] = "requested"]
  /\ UNCHANGED <<server, wire>>

Start(i) ==
  /\ i \in RequestedObservers /\ CanOwn /\ server.identity
  /\ server.lane = "idle"
  /\ (server.savePhysical \/ Bug = "overlap_original")
  /\ ((server.settled /\ server.authoritative) \/ Bug = "local_return_is_settlement")
  /\ server' = [server EXCEPT !.lane = Modes[i], !.laneOrigin = Modes[i],
       !.lanePhysical = FALSE, !.laneFact = "none", !.physicalCount = @ + 1]
  /\ clients' = [clients EXCEPT !.observation[i] = "active"]
  /\ wire' = [ready |-> FALSE]

Join(i) ==
  /\ i \in RequestedObservers /\ CanOwn /\ server.lane # "idle"
  /\ Modes[i] = server.lane
  /\ clients' = [clients EXCEPT !.observation[i] = "active"]
  /\ server' = [server EXCEPT !.joined = TRUE]
  /\ wire' = IF server.lanePhysical THEN [ready |-> TRUE] ELSE wire

RejectMixed(i) ==
  /\ i \in RequestedObservers /\ CanOwn /\ server.lane # "idle"
  /\ Modes[i] # server.lane
  /\ clients' = [clients EXCEPT !.observation[i] = "done", !.result[i] = "unavailable"]
  /\ server' = [server EXCEPT !.mixedRejected = TRUE,
       !.lane = IF Bug = "promote_read_to_retry" /\ Modes[i] = "retry"
                THEN "retry" ELSE @]
  /\ UNCHANGED wire

Unavailable(i) ==
  /\ i \in RequestedObservers
  /\ (server.runtime = "stopped" \/ ~server.identity \/ ~server.savePhysical)
  /\ clients' = [clients EXCEPT !.observation[i] = "done", !.result[i] = "unavailable"]
  /\ UNCHANGED <<server, wire>>

RepeatedReceipt(i) ==
  /\ i \in RequestedObservers /\ ~server.owned /\ server.applyCount = 1
  /\ clients' = [clients EXCEPT !.observation[i] = "done", !.result[i] = "confirmed_post"]
  /\ UNCHANGED <<server, wire>>

Classify ==
  IF ~server.authoritative THEN "unavailable"
  ELSE IF ~server.settled /\ Bug # "local_return_is_settlement" THEN "unavailable"
  ELSE CASE server.durable = "post" -> "confirmed_post"
         [] server.durable = "pre" -> "confirmed_pre"
         [] OTHER -> "unresolved"

(* One atomic compare-and-write abstraction: no read-to-write promotion, and
   no reuse of a previously confirmed pre-state after external interference. *)
CaptureWorker ==
  /\ server.lane # "idle" /\ server.laneFact = "none"
  /\ LET fact == IF Bug = "cache_pre" /\ server.lastFact = "confirmed_pre"
                  THEN "confirmed_pre" ELSE Classify
         write == server.lane = "retry" /\ fact = "confirmed_pre"
         result == IF write THEN "confirmed_post" ELSE fact
     IN server' = [server EXCEPT !.laneFact = result,
          !.durable = IF write THEN "post" ELSE @,
          !.writes = @ + IF write THEN 1 ELSE 0,
          !.businessRuns = @ + IF write /\ Bug = "replay_business" THEN 1 ELSE 0,
          !.readWrote = @ \/ (write /\ server.laneOrigin = "read"),
          !.overwroteConflict = @ \/ (write /\ server.durable = "conflict"),
          !.unsettledFact = @ \/ (result \in {"confirmed_pre", "confirmed_post"} /\ ~server.settled)]
  /\ UNCHANGED <<clients, wire>>

FinishWorkerPhysical ==
  /\ server.lane # "idle" /\ server.laneFact # "none" /\ ~server.lanePhysical
  /\ server' = [server EXCEPT !.lanePhysical = TRUE, !.physicalCount = @ - 1]
  /\ wire' = [ready |-> TRUE]
  /\ UNCHANGED clients

(* Logical observer cancellation does not destroy the physical slot or proof. *)
CancelObserver(i) ==
  /\ FaultEnabled("cancel") /\ i \in ActiveObservers
  /\ clients' = [clients EXCEPT !.observation[i] = "cancelled"]
  /\ server' = IF Bug = "cancel_drops_lane"
                THEN [server EXCEPT !.lane = "idle"] ELSE server
  /\ UNCHANGED wire

LoseNotification ==
  /\ FaultEnabled("notification_loss") /\ wire.ready /\ ~server.notificationLost
  /\ wire' = [ready |-> FALSE]
  /\ server' = [server EXCEPT !.notificationLost = TRUE]
  /\ clients' = [clients EXCEPT
       !.observation = [i \in Observers |-> IF i \in ActiveObservers THEN "done" ELSE clients.observation[i]],
       !.result = [i \in Observers |-> IF i \in ActiveObservers THEN "unavailable" ELSE clients.result[i]]]

(* A later explicit observation can inspect a physically completed mailbox;
   the lost notification itself does not promise eventual automatic repair. *)
Nudge ==
  /\ CanOwn /\ server.lane # "idle" /\ server.lanePhysical
  /\ RequestedObservers # {} /\ ~wire.ready
  /\ wire' = [ready |-> TRUE]
  /\ UNCHANGED <<server, clients>>

ApplyPost ==
  /\ CanOwn /\ server.laneFact = "confirmed_post"
  /\ (wire.ready \/ Bug = "release_before_physical")
  /\ (PhysicalQuiet \/ Bug = "release_before_physical")
  /\ (server.identity \/ Bug = "stale_apply")
  /\ (server.applyCount = 0 \/ (Bug = "duplicate_apply" /\ server.applyCount = 1))
  /\ server' = [server EXCEPT !.lastFact = "confirmed_post", !.applyCount = @ + 1,
       !.callbacks = @ + IF Bug = "replay_closed_callback" THEN 1 ELSE 0, !.staleApply = @ \/ ~server.identity]
  /\ clients' = IF Bug = "reopen_original"
                 THEN [clients EXCEPT !.original = "result"] ELSE clients
  /\ UNCHANGED wire

ReleasePost ==
  /\ CanOwn /\ server.applyCount = 1
  /\ (PhysicalQuiet \/ Bug = "release_before_physical")
  /\ server.identity
  /\ server' = [server EXCEPT !.owned = FALSE, !.custody = FALSE,
       !.admission = FALSE, !.releaseCount = @ + 1, !.lane = "idle"]
  /\ clients' = [clients EXCEPT
       !.observation = [i \in Observers |-> IF i \in ActiveObservers THEN "done" ELSE clients.observation[i]],
       !.result = [i \in Observers |-> IF i \in ActiveObservers THEN "confirmed_post" ELSE clients.result[i]]]
  /\ wire' = [ready |-> FALSE]

CloseUnapplied ==
  /\ CanOwn /\ wire.ready /\ PhysicalQuiet /\ server.lane # "idle"
  /\ server.laneFact # "none"
  /\ (server.laneFact # "confirmed_post" \/ ~server.identity)
  /\ server' = [server EXCEPT !.lastFact = server.laneFact, !.lane = "idle",
       !.owned = IF Bug = "release_pre" /\ server.laneFact = "confirmed_pre" THEN FALSE ELSE @,
       !.custody = IF Bug = "release_pre" /\ server.laneFact = "confirmed_pre" THEN FALSE ELSE @,
       !.admission = IF Bug = "release_pre" /\ server.laneFact = "confirmed_pre" THEN FALSE ELSE @]
  /\ clients' = [clients EXCEPT
       !.observation = [i \in Observers |-> IF i \in ActiveObservers THEN "done" ELSE clients.observation[i]],
       !.result = [i \in Observers |-> IF i \in ActiveObservers THEN server.laneFact ELSE clients.result[i]]]
  /\ wire' = [ready |-> FALSE]

LoseAuthoritativeRead ==
  /\ FaultEnabled("read_failure") /\ ~server.readLost /\ server.authoritative
  /\ server' = [server EXCEPT !.authoritative = FALSE, !.readLost = TRUE]
  /\ UNCHANGED <<clients, wire>>

RestoreAuthoritativeRead ==
  /\ ~server.authoritative /\ ~server.readRestored
  /\ server' = [server EXCEPT !.authoritative = TRUE, !.readRestored = TRUE]
  /\ UNCHANGED <<clients, wire>>

ChangeIdentity ==
  /\ FaultEnabled("identity_change") /\ server.owned /\ server.identity
  /\ server' = [server EXCEPT !.identity = FALSE]
  /\ UNCHANGED <<clients, wire>>

Interfere ==
  /\ FaultEnabled("interference") /\ ~server.interference
  /\ server.durable = "pre" /\ server.lane = "idle" /\ server.settled
  /\ server' = [server EXCEPT !.durable = "conflict", !.interference = TRUE]
  /\ UNCHANGED <<clients, wire>>

BeginShutdown ==
  /\ FaultEnabled("shutdown") /\ server.runtime = "live"
  /\ server' = [server EXCEPT !.runtime = "draining"]
  /\ UNCHANGED <<clients, wire>>

StopRuntime ==
  /\ FaultEnabled("shutdown") /\ server.runtime = "draining"
  /\ server' = [server EXCEPT !.runtime = "stopped",
       !.shutdownClean = ~server.owned \/ Bug = "shutdown_drops_custody",
       !.custody = IF Bug = "shutdown_drops_custody" THEN FALSE ELSE @,
       !.admission = IF Bug = "shutdown_drops_custody" THEN FALSE ELSE @]
  /\ clients' = [clients EXCEPT
       !.observation = [i \in Observers |-> IF i \in ActiveObservers THEN "done" ELSE clients.observation[i]],
       !.result = [i \in Observers |-> IF i \in ActiveObservers THEN "unavailable" ELSE clients.result[i]]]
  /\ UNCHANGED wire

Next ==
  \/ \E outcome \in {"pre", "post"}: SettleBackend(outcome)
  \/ FinishOriginalPhysical
  \/ \E i \in Observers: Request(i) \/ Start(i) \/ Join(i) \/ RejectMixed(i)
                          \/ Unavailable(i) \/ RepeatedReceipt(i) \/ CancelObserver(i)
  \/ CaptureWorker \/ FinishWorkerPhysical \/ LoseNotification \/ Nudge
  \/ ApplyPost \/ ReleasePost \/ CloseUnapplied
  \/ ChangeIdentity \/ Interfere \/ BeginShutdown \/ StopRuntime
  \/ LoseAuthoritativeRead \/ RestoreAuthoritativeRead

Spec == Init /\ [][Next]_vars
ProgressSpec == Spec
  /\ WF_vars(Request(1)) /\ WF_vars(Start(1))
  /\ WF_vars(CaptureWorker) /\ WF_vars(FinishWorkerPhysical)
  /\ WF_vars(ApplyPost) /\ WF_vars(ReleasePost)
  /\ WF_vars(FinishOriginalPhysical)
BackendProgressSpec == ProgressSpec /\ WF_vars(\E outcome \in {"pre", "post"}: SettleBackend(outcome))

TypeOK ==
  /\ server.runtime \in {"live", "draining", "stopped"}
  /\ server.lane \in {"idle", "read", "retry"}
  /\ server.laneFact \in Facts /\ server.lastFact \in Facts
  /\ server.durable \in {"pre", "post", "conflict"}
  /\ server.physicalCount \in 0..2 /\ server.applyCount \in 0..2
  /\ server.writes \in 0..2
  /\ clients.original \in {"recovery_error", "result"}
  /\ clients.observation \in [Observers -> {"unused", "requested", "active", "done", "cancelled"}]
  /\ clients.result \in [Observers -> Facts]
PhysicalSerialization == server.physicalCount <= 1
PhysicalCustody == server.physicalCount > 0 =>
  (server.custody /\ (~server.savePhysical \/ server.lane # "idle"))
OriginalNeverReopened == clients.original = "recovery_error"
PreKeepsOwnership == server.lastFact = "confirmed_pre" => server.owned /\ server.admission /\ server.custody
ReleaseRequiresAppliedPost == ~server.owned =>
  (server.applyCount = 1 /\ server.lastFact = "confirmed_post" /\ PhysicalQuiet)
ApplyOnce == server.applyCount <= 1 /\ server.callbacks <= 1
ClosedObserverNoCallback == server.callbacks = 0
ExactOwnerApplication == ~server.staleApply
NoBusinessReplay == server.businessRuns = 1
ReadNeverWrites == ~server.readWrote
NoConflictOverwrite == ~server.overwroteConflict
BackendFactsNeedSettlement == ~server.unsettledFact
CustodyUntilRelease == server.owned => server.custody /\ server.admission
ShutdownTruthful == server.shutdownClean => ~server.owned /\ PhysicalQuiet

EventuallyReleased == <>~server.owned
WitnessNoSharedRead == ~server.joined
WitnessNoMixedRefusal == ~server.mixedRejected
WitnessNoCancelledReadResult == ~(clients.observation[1] = "cancelled" /\ clients.result[2] = "confirmed_post")
WitnessNoFreshRetry == ~(server.lastFact = "confirmed_pre" /\ server.interference /\ server.laneFact = "unresolved")
WitnessNoLatePhysical == ~(Profile = "pending" /\ server.savePhysical /\ server.releaseCount = 1)
WitnessNoShutdownRetention == ~(server.runtime = "stopped" /\ server.owned /\ server.custody /\ ~server.shutdownClean)
WitnessNoLostNotificationRecovery == ~(server.notificationLost /\ server.releaseCount = 1)
=============================================================================
