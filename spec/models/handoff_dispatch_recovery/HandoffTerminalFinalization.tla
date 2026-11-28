-------------------- MODULE HandoffTerminalFinalization --------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Outcome, Fault, ReadMode, RestoreReads, FreshCalls, ReleaseCustody,
          Held, Concurrent, AdvanceHistory, Mismatch, MonotonicCustody, Bug

VARIABLES route, custody, agents, callers, metrics, bad, reads, faultUsed, advanced, stamps
vars == <<route, custody, agents, callers, metrics, bad, reads, faultUsed, advanced, stamps>>
Roles == {"source", "target"}
Actors == 1..2
EnabledActors == IF Concurrent THEN Actors ELSE {1}
IdentityFields == {"anchor", "source_id", "target_id", "active_agent", "reservation", "store"}
ReceiptFields == {"source_status", "receipt", "context", "source_metadata", "target_status", "target_result", "active_execution"}
HoldFields == {"main_hold", "source_hold", "target_hold"}
DomainFields == IdentityFields \cup ReceiptFields \cup HoldFields
BadFields == DomainFields \cup {"query_identity"}
OriginalOutcome == [status |-> Outcome, error |-> "original_error", execution |-> 1]
InitialRoute == [epoch |-> 1, phase |-> "pending", revision |-> 1, stamp |-> 0]

Init ==
 /\ bad \in IF Mismatch = "any" THEN BadFields \cup {"none"} ELSE
       IF Mismatch \in {"post_drift", "pre_drift"} THEN {"none"} ELSE {Mismatch}
 /\ stamps \in IF Concurrent THEN [Actors -> {1, 2}] ELSE {[i \in Actors |-> 1]}
 /\ route = InitialRoute
 /\ custody = [state |-> [r \in Roles |-> IF Held = "both" \/ Held = r THEN "held" ELSE "released"],
      reacquired |-> FALSE]
 /\ agents = [outcome |-> OriginalOutcome, history |-> TRUE]
 /\ callers = [i \in Actors |-> [phase |-> "idle", started |-> FALSE,
      snapshot |-> InitialRoute, checked |-> FALSE, writes |-> 0,
      intended |-> InitialRoute, firstResult |-> "unused"]]
 /\ metrics = [writes |-> 0, attempts |-> 0, exactChain |-> TRUE,
      authority |-> TRUE, custody |-> TRUE, queryIdentity |-> TRUE,
      confirmations |-> TRUE, businessCalls |-> 0, finalizedObservation |-> FALSE,
      resultVisible |-> FALSE, readonlyWrites |-> 0, historyWrites |-> 0,
      lastCommitter |-> 0, competingExactPost |-> FALSE]
 /\ reads = (ReadMode # "initially_unavailable")
 /\ faultUsed = (Fault = "none")
 /\ advanced = FALSE

AllReleased == \A r \in Roles : custody.state[r] = "released"
QueryGrant ==
 /\ bad # "query_identity" \/ Bug = "foreign_query"
 /\ \A r \in Roles : custody.state[r] = "released" \/
      (r = "source" /\ Bug = "ignore_source_custody") \/
      (r = "target" /\ Bug = "ignore_target_custody") \/ Bug = "foreign_query"
IdentityValid == bad \notin IdentityFields
ReceiptValid == bad \notin ReceiptFields
HoldsValid == bad \notin HoldFields
DomainValid == IdentityValid /\ ReceiptValid /\ HoldsValid
DomainGrant ==
 /\ IdentityValid \/ Bug = "skip_identity"
 /\ ReceiptValid \/ Bug = "skip_receipt"
 /\ HoldsValid \/ Bug = "skip_hold"
ExactBefore(i) == route = callers[i].snapshot /\ DomainValid
CompatibleStable(i) == route.epoch = callers[i].snapshot.epoch /\
 route.phase = "stable" /\ route.revision = callers[i].snapshot.revision + 1 /\ DomainValid
ExactPost(i) == route = callers[i].intended /\ DomainValid /\ agents.outcome = OriginalOutcome /\ agents.history
FirstClosed(i, result) == IF callers[i].firstResult = "pending" THEN result ELSE callers[i].firstResult

ReleaseChild(r) ==
 /\ r \in Roles /\ ReleaseCustody /\ custody.state[r] = "held"
 /\ custody' = [custody EXCEPT !.state[r] = "released"]
 /\ UNCHANGED <<route, agents, callers, metrics, bad, reads, faultUsed, advanced, stamps>>

RestoreRead ==
 /\ RestoreReads /\ ~reads
 /\ reads' = TRUE
 /\ UNCHANGED <<route, custody, agents, callers, metrics, bad, faultUsed, advanced, stamps>>

ReadResult ==
 /\ reads /\ ~metrics.resultVisible
 /\ metrics' = [metrics EXCEPT !.resultVisible = TRUE]
 /\ UNCHANGED <<route, custody, agents, callers, bad, reads, faultUsed, advanced, stamps>>

StartCall(i) ==
 /\ i \in EnabledActors /\ callers[i].phase \in {"idle", "error"}
 /\ FreshCalls \/ ~callers[i].started
 /\ callers' = [callers EXCEPT ![i].phase = "snapshot", ![i].started = TRUE,
      ![i].checked = FALSE, ![i].writes = 0, ![i].snapshot = InitialRoute, ![i].intended = InitialRoute,
      ![i].firstResult = IF @ = "unused" THEN "pending" ELSE @]
 /\ UNCHANGED <<route, custody, agents, metrics, bad, reads, faultUsed, advanced, stamps>>

(* The first complete domain snapshot is captured before either custody query. *)
CapturePending(i) ==
 /\ i \in EnabledActors /\ callers[i].phase = "snapshot"
 /\ IF ~reads
      THEN /\ callers' = [callers EXCEPT ![i].phase = "error", ![i].firstResult = FirstClosed(i, "error")]
           /\ UNCHANGED metrics
      ELSE IF route.epoch # 1 \/ route.phase = "stable"
           THEN /\ callers' = [callers EXCEPT ![i].phase = "done", ![i].firstResult = FirstClosed(i, "done")]
                /\ metrics' = [metrics EXCEPT !.finalizedObservation = @ \/ (route.epoch = 1 /\ route.phase = "stable")]
           ELSE /\ callers' = [callers EXCEPT
                     ![i].phase = IF DomainGrant THEN "query" ELSE "error",
                     ![i].snapshot = route,
                     ![i].firstResult = IF DomainGrant THEN @ ELSE FirstClosed(i, "error")]
                /\ UNCHANGED metrics
 /\ UNCHANGED <<route, custody, agents, bad, reads, faultUsed, advanced, stamps>>

(* This abstracts two Agent-owned, serialized observations, outside Store locks.
   It does not assert that every queued observer or historical owner is absent. *)
QueryCustody(i) ==
 /\ i \in EnabledActors /\ callers[i].phase = "query"
 /\ callers' = [callers EXCEPT ![i].phase = IF QueryGrant THEN "guarded" ELSE "error",
      ![i].checked = QueryGrant,
      ![i].firstResult = IF QueryGrant THEN @ ELSE FirstClosed(i, "error")]
 /\ metrics' = [metrics EXCEPT !.queryIdentity = @ /\ (~QueryGrant \/ bad # "query_identity")]
 /\ UNCHANGED <<route, custody, agents, bad, reads, faultUsed, advanced, stamps>>

(* This whole action is one routing-first, ordered-Agent-guard transaction. *)
GuardedFinalization(i) ==
 /\ i \in EnabledActors /\ callers[i].phase = "guarded"
 /\ LET already == reads /\ CompatibleStable(i) /\ Bug # "duplicate_write"
        write == reads /\ ~already /\ DomainGrant /\
          ((route = callers[i].snapshot /\ route.phase = "pending" /\ route.epoch = 1) \/
           (Bug = "duplicate_write" /\ route.phase = "stable" /\ route.epoch = 1 /\ metrics.writes = 1) \/
           (Bug = "historical_write" /\ route.epoch = 2))
        fault == write /\ ~faultUsed
        committed == write /\ (~fault \/ Fault = "post")
        intended == [route EXCEPT !.phase = "stable", !.revision = @ + 1, !.stamp = stamps[i]]
    IN /\ route' = IF committed THEN intended ELSE route
       /\ faultUsed' = (faultUsed \/ write)
       /\ reads' = IF fault /\ ReadMode = "lost_after_fault" THEN FALSE ELSE reads
       /\ callers' = [callers EXCEPT
          ![i].phase = IF already THEN "done" ELSE IF write THEN IF fault THEN "proof" ELSE "done" ELSE "error",
          ![i].intended = IF write THEN intended ELSE @,
          ![i].writes = @ + IF write THEN 1 ELSE 0,
          ![i].firstResult = IF already \/ (write /\ ~fault) THEN FirstClosed(i, "done")
            ELSE IF ~write THEN FirstClosed(i, "error") ELSE @]
       /\ metrics' = [metrics EXCEPT
          !.writes = @ + IF committed THEN 1 ELSE 0,
          !.attempts = @ + IF write THEN 1 ELSE 0,
          !.lastCommitter = IF committed THEN i ELSE @,
          !.exactChain = @ /\ (~write \/ (route.epoch = 1 /\ IdentityValid)),
          !.authority = @ /\ (~write \/ DomainValid),
          !.custody = @ /\ (~write \/ (AllReleased /\ callers[i].checked)),
          !.businessCalls = @ + IF write /\ Bug = "replay_business" THEN 1 ELSE 0,
          !.finalizedObservation = @ \/ already \/ (write /\ ~fault)]
       /\ agents' = IF write /\ Bug = "replace_outcome"
           THEN [agents EXCEPT !.outcome = [status |-> "cancelled", error |-> "routing_error", execution |-> 1]] ELSE agents
 /\ UNCHANGED <<custody, bad, advanced, stamps>>

ReadBack(i) ==
 /\ i \in EnabledActors /\ callers[i].phase = "proof"
 /\ LET confirmed == IF Bug = "unknown_as_post" THEN TRUE ELSE
         reads /\ IF Bug = "partial_post" THEN route.phase = "stable" ELSE ExactPost(i)
    IN /\ callers' = [callers EXCEPT ![i].phase = IF confirmed THEN "done" ELSE "error",
             ![i].firstResult = FirstClosed(i, IF confirmed THEN "done" ELSE "error")]
       /\ metrics' = [metrics EXCEPT
             !.confirmations = @ /\ (~confirmed \/ (reads /\ ExactPost(i))),
             !.finalizedObservation = @ \/ confirmed,
             !.competingExactPost = @ \/ (confirmed /\ reads /\ ExactPost(i) /\ metrics.lastCommitter # i)]
 /\ UNCHANGED <<route, custody, agents, bad, reads, faultUsed, advanced, stamps>>

AdvanceOtherChain ==
 /\ AdvanceHistory /\ ~advanced /\ route.epoch = 1 /\ route.phase = "stable"
 /\ route' = [epoch |-> 2, phase |-> "pending", revision |-> route.revision + 1, stamp |-> 9]
 /\ advanced' = TRUE
 /\ UNCHANGED <<custody, agents, callers, metrics, bad, reads, faultUsed, stamps>>

ChangeBeforeGuard ==
 /\ Mismatch \in {"any", "pre_drift"} /\ bad = "none"
 /\ \E i \in Actors : callers[i].phase = "guarded"
 /\ bad' \in IF Mismatch = "pre_drift" THEN {"source_id"} ELSE DomainFields
 /\ UNCHANGED <<route, custody, agents, callers, metrics, reads, faultUsed, advanced, stamps>>

CorruptReadback ==
 /\ Mismatch = "post_drift" /\ bad = "none" /\ faultUsed
 /\ \E i \in Actors : callers[i].phase = "proof"
 /\ bad' = "target_hold"
 /\ UNCHANGED <<route, custody, agents, callers, metrics, reads, faultUsed, advanced, stamps>>

ReacquireTerminalCustody ==
 /\ ~MonotonicCustody /\ ~custody.reacquired /\ AllReleased
 /\ \E i \in Actors : callers[i].phase = "guarded"
 /\ custody' = [custody EXCEPT !.state["source"] = "held", !.reacquired = TRUE]
 /\ UNCHANGED <<route, agents, callers, metrics, bad, reads, faultUsed, advanced, stamps>>

Next == (\E r \in Roles : ReleaseChild(r)) \/ RestoreRead \/ ReadResult \/
 (\E i \in Actors : StartCall(i) \/ CapturePending(i) \/ QueryCustody(i) \/ GuardedFinalization(i) \/ ReadBack(i)) \/
 AdvanceOtherChain \/ ChangeBeforeGuard \/ CorruptReadback \/ ReacquireTerminalCustody
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(RestoreRead) /\
 (\A r \in Roles : WF_vars(ReleaseChild(r))) /\
 (\A i \in Actors : WF_vars(StartCall(i)) /\ WF_vars(CapturePending(i)) /\
   WF_vars(QueryCustody(i)) /\ WF_vars(GuardedFinalization(i)) /\ WF_vars(ReadBack(i)))

TypeOK == route.phase \in {"pending", "stable"} /\ route.epoch \in {1, 2} /\
 (\A r \in Roles : custody.state[r] \in {"held", "released"}) /\
 (\A i \in Actors : callers[i].phase \in {"idle", "snapshot", "query", "guarded", "proof", "error", "done"}) /\
 metrics.writes \in 0..2 /\ metrics.attempts \in 0..3
CustodyBeforeFinalization == metrics.custody
QueryBoundToIdentity == metrics.queryIdentity
CurrentChainOnly == metrics.exactChain
SourceTargetAuthority == metrics.authority
PreservedOutcome == agents.outcome = OriginalOutcome
HistoryRetained == agents.history /\ metrics.historyWrites = 0
ResultReadOnly == metrics.readonlyWrites = 0
NoBusinessReplay == metrics.businessCalls = 0
OneFinalizationWrite == metrics.writes <= 1
NoFalseConfirmation == metrics.confirmations
FreshRequestForRetry == \A i \in Actors : callers[i].writes <= 1
EventuallyStable == <>(route.phase = "stable" \/ advanced)
EventuallyObserved == <>metrics.finalizedObservation
NeverVisiblePending == ~(metrics.resultVisible /\ route.epoch = 1 /\ route.phase = "pending")
NeverHeldRejection == ~((\E r \in Roles : custody.state[r] = "held") /\
 (\E i \in Actors : callers[i].phase = "error") /\ route.phase = "pending")
NeverStableUnknown == ~(route.epoch = 1 /\ route.phase = "stable" /\
 ~reads /\ (\E i \in Actors : callers[i].phase = "error"))
NeverConcurrentCompletion == ~((\A i \in Actors : callers[i].phase = "done" /\ callers[i].checked) /\
 metrics.writes = 1 /\ metrics.competingExactPost)
=============================================================================
