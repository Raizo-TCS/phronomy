----------------------- MODULE RecoverySubmissionCustody -----------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Boundary, Fault, FreshCaller, Bug
VARIABLES owner, slots, callers
vars == <<owner, slots, callers>>
Ids == 1..3
AttemptIds == 2..3
LiveStates == {"queued", "running", "recorded"}
AcceptedStates == LiveStates \cup {"quiet"}
FaultEnabled(name) == Fault = "all" \/ Fault = name
LostHandleEnabled == FaultEnabled("lost_handle") \/ Fault = "accepted_lost_handle"
First == IF Boundary = "initial" THEN 1 ELSE 2

EmptySlot == [submission |-> "unused", pool |-> "none", handle |-> FALSE,
  refusal |-> FALSE, entered |-> FALSE, lost |-> FALSE, rejected |-> FALSE,
  physical |-> FALSE, result |-> "none", watch |-> TRUE]
StartedSlot == [EmptySlot EXCEPT !.submission = "submitting"]
SettledInitial == [EmptySlot EXCEPT !.submission = "returned", !.pool = "quiet",
  !.handle = TRUE, !.entered = TRUE, !.physical = TRUE, !.result = "uncertain"]

(* The initial save has a separate physical barrier. Later observations cannot
   replace it or discard an already accepted recovery attempt. *)
Init ==
  /\ owner = [active |-> First, next |-> First + 1, confirmed |-> FALSE,
       applied |-> FALSE, released |-> FALSE, held |-> TRUE, live |-> TRUE]
  /\ slots = [i \in Ids |-> IF i = First THEN StartedSlot
       ELSE IF i = 1 /\ Boundary # "initial" THEN SettledInitial ELSE EmptySlot]
  /\ callers = [state |-> [i \in Ids |-> IF i = First THEN "pending"
       ELSE IF i = 1 /\ Boundary # "initial" THEN "closed" ELSE "unused"],
       closed |-> [i \in Ids |-> i = 1 /\ Boundary # "initial"]]

CanAccept(i) == Fault # "first_refused" \/ i # First
CanRefuse(i) == FaultEnabled("refusal") \/ (Fault = "first_refused" /\ i = First)

Accept(i) ==
  /\ slots[i].submission = "submitting" /\ slots[i].pool = "none" /\ CanAccept(i)
  /\ slots' = [slots EXCEPT ![i].pool = "queued"]
  /\ UNCHANGED <<owner, callers>>

Refuse(i) ==
  /\ slots[i].submission = "submitting" /\ slots[i].pool = "none" /\ CanRefuse(i)
  /\ slots' = [slots EXCEPT ![i].pool = "refused", ![i].refusal = TRUE]
  /\ UNCHANGED <<owner, callers>>

(* A legacy submitter may throw before accepting work without offering proof.
   Its actual refusal is deliberately not available as owner knowledge. *)
SilentRefuse(i) ==
  /\ FaultEnabled("lost_handle")
  /\ slots[i].submission = "submitting" /\ slots[i].pool = "none"
  /\ slots' = [slots EXCEPT ![i].pool = "silent_refused"]
  /\ UNCHANGED <<owner, callers>>

ReturnHandle(i) ==
  /\ slots[i].submission = "submitting" /\ slots[i].pool \in AcceptedStates
  /\ slots' = [slots EXCEPT ![i].submission = "returned", ![i].handle = TRUE]
  /\ UNCHANGED <<owner, callers>>

Throw(i) ==
  /\ slots[i].submission = "submitting"
  /\ slots[i].pool \in {"refused", "silent_refused"} \/
       (LostHandleEnabled /\ slots[i].pool \in AcceptedStates)
  /\ LET proof == slots[i].refusal /\ ~slots[i].handle /\ ~slots[i].entered
         refused == proof \/ Bug = "no_handle_is_refusal"
     IN /\ slots' = [slots EXCEPT ![i].submission = "thrown", ![i].lost = ~proof,
               ![i].rejected = refused, ![i].physical = refused]
        /\ callers' = [callers EXCEPT !.state[i] = "closed", !.closed[i] = TRUE]
  /\ UNCHANGED owner

Enter(i) ==
  /\ slots[i].pool = "queued"
  /\ slots' = [slots EXCEPT ![i].pool = "running", ![i].entered = TRUE]
  /\ UNCHANGED <<owner, callers>>

(* A worker mailbox value precedes its executor's physical-completion event.
   A lost handle has no usable completion channel, even after a late result. *)
Record(i) ==
  /\ slots[i].pool = "running"
  /\ slots' = [slots EXCEPT ![i].pool = "recorded",
       ![i].result = IF i = 1 THEN "uncertain" ELSE "post",
       ![i].physical = @ \/ (Bug = "result_is_physical" /\ slots[i].lost)]
  /\ UNCHANGED <<owner, callers>>

Quiet(i) ==
  /\ slots[i].pool = "recorded"
  /\ slots' = [slots EXCEPT ![i].pool = "quiet"]
  /\ UNCHANGED <<owner, callers>>

LoseWatch(i) ==
  /\ FaultEnabled("callback_loss")
  /\ slots[i].handle /\ slots[i].watch /\ ~slots[i].physical
  /\ slots' = [slots EXCEPT ![i].watch = FALSE]
  /\ callers' = [callers EXCEPT !.state[i] = "closed", !.closed[i] = TRUE]
  /\ UNCHANGED owner

ObservePhysical(i) ==
  /\ owner.live /\ slots[i].handle /\ slots[i].pool = "quiet" /\ ~slots[i].physical
  /\ slots[i].watch \/ FreshCaller
  /\ slots' = [slots EXCEPT ![i].physical = TRUE]
  /\ UNCHANGED <<owner, callers>>

CloseCaller(i) ==
  /\ FaultEnabled("caller_closure") /\ callers.state[i] = "pending"
  /\ callers' = [callers EXCEPT !.state[i] = "closed", !.closed[i] = TRUE]
  /\ UNCHANGED <<owner, slots>>

Finish(i) ==
  /\ owner.live /\ owner.active = i /\ slots[i].physical
  /\ slots[i].submission \in {"returned", "thrown"}
  /\ owner' = [owner EXCEPT !.active = 0,
       !.confirmed = @ \/ slots[i].result = "post" \/ (i = 1 /\ slots[i].rejected)]
  /\ callers' = [callers EXCEPT !.state[i] = IF callers.closed[i] THEN "closed" ELSE "done"]
  /\ UNCHANGED slots

(* The old implementation forgot an unreturned recovery task. The mutation
   permits another request even while that hidden task remains physically live. *)
ForgetUnknown(i) ==
  /\ Bug = "forget_unknown_attempt" /\ i \in AttemptIds
  /\ owner.active = i /\ slots[i].lost /\ ~slots[i].physical
  /\ owner' = [owner EXCEPT !.active = 0]
  /\ UNCHANGED <<slots, callers>>

FreshObservation ==
  /\ FreshCaller /\ owner.live /\ owner.held /\ ~owner.released /\ ~owner.confirmed
  /\ owner.active = 0 /\ owner.next \in AttemptIds /\ slots[1].physical
  /\ LET i == owner.next IN
       /\ owner' = [owner EXCEPT !.active = i, !.next = i + 1]
       /\ slots' = [slots EXCEPT ![i] = StartedSlot]
       /\ callers' = [callers EXCEPT !.state[i] = "pending"]

Apply ==
  /\ owner.live /\ owner.confirmed /\ owner.active = 0 /\ ~owner.applied
  /\ owner' = [owner EXCEPT !.applied = TRUE]
  /\ UNCHANGED <<slots, callers>>

Release ==
  /\ owner.live /\ owner.applied /\ owner.active = 0 /\ ~owner.released
  /\ owner' = [owner EXCEPT !.released = TRUE, !.held = FALSE]
  /\ UNCHANGED <<slots, callers>>

Stop ==
  /\ FaultEnabled("shutdown") /\ owner.live
  /\ owner' = [owner EXCEPT !.live = FALSE]
  /\ callers' = [callers EXCEPT
       !.state = [i \in Ids |-> IF callers.state[i] = "pending" THEN "closed" ELSE callers.state[i]],
       !.closed = [i \in Ids |-> callers.closed[i] \/ callers.state[i] = "pending"]]
  /\ UNCHANGED slots

Next ==
  \/ \E i \in Ids : Accept(i) \/ Refuse(i) \/ SilentRefuse(i) \/ ReturnHandle(i) \/ Throw(i)
       \/ Enter(i) \/ Record(i) \/ Quiet(i) \/ LoseWatch(i) \/ ObservePhysical(i)
       \/ CloseCaller(i) \/ Finish(i) \/ ForgetUnknown(i)
  \/ FreshObservation \/ Apply \/ Release \/ Stop

Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(FreshObservation) /\ WF_vars(Apply) /\ WF_vars(Release)
  /\ \A i \in Ids : WF_vars(Accept(i)) /\ WF_vars(Refuse(i)) /\ WF_vars(ReturnHandle(i))
       /\ WF_vars(Throw(i)) /\ WF_vars(Enter(i)) /\ WF_vars(Record(i))
       /\ WF_vars(Quiet(i)) /\ WF_vars(ObservePhysical(i)) /\ WF_vars(Finish(i))

TypeOK ==
  /\ owner.active \in 0..3 /\ owner.next \in 2..4
  /\ {owner.confirmed, owner.applied, owner.released, owner.held, owner.live} \subseteq BOOLEAN
  /\ \A i \in Ids :
       /\ slots[i].submission \in {"unused", "submitting", "returned", "thrown"}
       /\ slots[i].pool \in {"none", "refused", "silent_refused"} \cup AcceptedStates
       /\ slots[i].result \in {"none", "uncertain", "post"}
       /\ {slots[i].handle, slots[i].refusal, slots[i].entered, slots[i].lost,
            slots[i].rejected, slots[i].physical, slots[i].watch, callers.closed[i]} \subseteq BOOLEAN
       /\ callers.state[i] \in {"unused", "pending", "closed", "done"}

NonAdmissionNeedsProof == \A i \in Ids : slots[i].rejected =>
  slots[i].refusal /\ ~slots[i].handle /\ ~slots[i].entered /\ slots[i].pool = "refused"
CompletionNeedsEvidence == \A i \in Ids : slots[i].physical =>
  (slots[i].handle /\ slots[i].pool = "quiet") \/
  (slots[i].refusal /\ slots[i].pool = "refused")
UnknownSlotRetained == \A i \in Ids : slots[i].lost /\ ~slots[i].physical =>
  owner.active = i /\ owner.held /\ ~owner.released
InitialBarrier == owner.active \in AttemptIds => slots[1].physical
PhysicalSerialization == Cardinality({i \in Ids : slots[i].pool \in LiveStates}) <= 1
ReleaseSafe == owner.released => owner.applied /\ owner.confirmed /\
  (\A i \in Ids : slots[i].submission # "unused" => slots[i].physical) /\
  (\A i \in Ids : slots[i].pool \notin LiveStates)
ClosedCallerStaysClosed == \A i \in Ids : callers.closed[i] => callers.state[i] = "closed"
CustodyUntilRelease == ~owner.released => owner.held
EventuallyReleased == <>owner.released

NoUnknownQuietWitness == ~\E i \in Ids : slots[i].lost /\ slots[i].pool = "quiet" /\
  ~slots[i].physical /\ owner.active = i /\ owner.held
NoRefusalThenAcceptanceWitness == ~(Boundary # "initial" /\ slots[2].rejected /\
  slots[3].pool \in AcceptedStates)
NoClosedCallerReleaseWitness == ~(owner.released /\ \E i \in Ids : callers.closed[i] /\ slots[i].handle)
NoReturnedQueuedWitness == ~\E i \in Ids : slots[i].handle /\ slots[i].pool = "queued" /\
  ~slots[i].physical /\ owner.active = i
=============================================================================
