----------------------- MODULE ParentChildResultImport -----------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Outcome, ParentOutcome, Sibling, Ready, Finishing, MatchSlot, MatchReservation,
          Imported, Save, Reply, Readable, UnloadReadable, Cleanup, Caller, Drift, Bug
VARIABLES child, parent, attempt, client, release
vars == <<child, parent, attempt, client, release>>
Children == 1..2
Terminal(s) == s \in {"succeeded", "failed", "cancelled"}
None == "none"
NoReceipt == [version |-> 0, slot |-> 0, identity |-> 0,
  reservation |-> 0, status |-> "none", digest |-> 0]
Relationship(i) == child.slot[i] = i /\ child.reservation[i] = i
Receipt(i) == [version |-> 1, slot |-> child.slot[i], identity |-> i,
  reservation |-> child.reservation[i], status |-> child.status[i],
  digest |-> child.content[i]]
Eligible(i) ==
 /\ Finishing \/ Bug = "ack_wait"
 /\ Terminal(child.status[i]) \/ Bug = "ack_active"
 /\ child.slot[i] = i \/ Bug = "ignore_slot"
 /\ child.reservation[i] = i \/ Bug = "ignore_reservation"
Acknowledgements == [i \in Children |->
  IF ~parent.imported[i] /\ Eligible(i) THEN Receipt(i) ELSE parent.ack[i]]
MatchesReceipt(i) ==
 /\ parent.ack[i] # NoReceipt
 /\ IF Bug = "ignore_digest" THEN
      [parent.ack[i] EXCEPT !.digest = child.content[i]] = Receipt(i)
    ELSE parent.ack[i] = Receipt(i)
CurrentDisposition(i) == parent.imported[i] \/ MatchesReceipt(i)
ExactCurrentDisposition(i) == parent.imported[i] \/ parent.ack[i] = Receipt(i)

Init ==
 /\ child = [status |-> [i \in Children |->
       IF i = 1 THEN IF Ready THEN Outcome ELSE "active" ELSE Sibling],
       slot |-> [i \in Children |-> IF i = 1 /\ ~MatchSlot THEN 3 ELSE i],
       reservation |-> [i \in Children |-> IF i = 1 /\ ~MatchReservation THEN 3 ELSE i],
       content |-> [i \in Children |-> 1],
       holds |-> [i \in Children |-> TRUE],
       cancelled |-> FALSE, holdVersion |-> 1,
       ownerHeld |-> TRUE, physical |-> FALSE, businessRuns |-> 1]
 /\ parent = [state |-> "active", outcome |-> "pending",
       imported |-> [i \in Children |-> i = 1 /\ Imported],
       ack |-> [i \in Children |-> NoReceipt], ackValid |-> TRUE,
       hold |-> TRUE, ownerHeld |-> TRUE, physical |-> FALSE]
 /\ attempt = [phase |-> "ready", known |-> "unknown", changed |-> FALSE,
       commitCount |-> 0, childVersion |-> 1]
 /\ client = [original |-> "pending", closed |-> None]
 /\ release = [unloaded |-> FALSE, valid |-> TRUE]

ChildCompletes ==
 /\ child.status[1] = "active"
 /\ child' = [child EXCEPT !.status[1] = Outcome]
 /\ UNCHANGED <<parent, attempt, client, release>>

(* Reading the exact result here is the parent's new custody observation.
   It does not assert a previous Tool callback or successful business import. *)
CommitParent ==
 /\ attempt.phase = "ready"
 /\ LET acknowledged == Acknowledgements
        changed == \E i \in Children : acknowledged[i] # NoReceipt
        valid == \A i \in Children : acknowledged[i] # NoReceipt =>
          Finishing /\ Terminal(child.status[i]) /\ Relationship(i)
        committed == Save = "post"
    IN /\ parent' = [parent EXCEPT
           !.state = IF committed /\ Finishing THEN "terminal" ELSE @,
           !.outcome = IF committed /\ Finishing THEN
             IF Bug = "change_parent_outcome" THEN "succeeded" ELSE ParentOutcome ELSE @,
           !.ack = IF committed \/ Bug = "non_atomic_ack" THEN acknowledged ELSE @,
           !.ackValid = @ /\ (~committed \/ valid),
           !.imported = IF committed /\ changed /\ Bug = "ack_is_import" THEN
                         [i \in Children |-> acknowledged[i] # NoReceipt \/ @ [i]] ELSE @,
           !.hold = IF committed /\ changed /\ Bug = "drop_holds" THEN FALSE ELSE @]
       /\ child' = [child EXCEPT
           !.holds = IF committed /\ changed /\ Bug = "drop_holds"
                     THEN [i \in Children |-> FALSE] ELSE @,
           !.businessRuns = @ + IF Bug = "replay_business" THEN 1 ELSE 0]
       /\ attempt' = [attempt EXCEPT !.phase = "returned",
           !.commitCount = IF committed THEN 1 ELSE 0,
           !.childVersion = child.holdVersion,
           !.known = IF Reply = "normal" THEN
                       IF committed THEN "post" ELSE "pre" ELSE "unknown"]
 /\ UNCHANGED <<client, release>>

ReadParentProof ==
 /\ attempt.phase = "returned" /\ attempt.known = "unknown" /\ Readable
 /\ Bug # "freeze_child_holds" \/ child.holdVersion = attempt.childVersion
 /\ attempt' = [attempt EXCEPT !.known = IF Save = "post" THEN "post" ELSE "pre"]
 /\ UNCHANGED <<child, parent, client, release>>

CloseOriginal ==
 /\ attempt.phase = "returned" /\ client.original = "pending"
 /\ attempt.known # "unknown" \/ ~Readable
 /\ client' = [original |-> "failed", closed |-> "failed"]
 /\ UNCHANGED <<child, parent, attempt, release>>

FinishChildOwner ==
 /\ Cleanup /\ Terminal(child.status[1]) /\ child.ownerHeld
 /\ child' = [child EXCEPT !.ownerHeld = FALSE, !.physical = TRUE]
 /\ UNCHANGED <<parent, attempt, client, release>>
FinishParentOwner ==
 /\ Cleanup /\ attempt.phase = "returned" /\ parent.ownerHeld
 /\ parent' = [parent EXCEPT !.ownerHeld = FALSE, !.physical = TRUE]
 /\ UNCHANGED <<child, attempt, client, release>>

ChangeChildEvidence ==
 /\ Drift # "none" /\ attempt.phase = "returned" /\ ~attempt.changed /\ ~release.unloaded
 /\ child' = CASE Drift = "result" -> [child EXCEPT !.content[1] = 2]
              [] Drift = "reservation" -> [child EXCEPT !.reservation[1] = 3]
              [] Drift = "cancellation" -> [child EXCEPT !.cancelled = TRUE]
              [] OTHER -> [child EXCEPT !.holdVersion = 2]
 /\ attempt' = [attempt EXCEPT !.changed = TRUE]
 /\ UNCHANGED <<parent, client, release>>

(* A fresh guarded domain read is independent of the original save response. *)
UnloadPair ==
 /\ Caller /\ UnloadReadable /\ ~release.unloaded /\ parent.state = "terminal"
 /\ Sibling = "absent" /\ Terminal(child.status[1]) /\ Relationship(1)
 /\ CurrentDisposition(1) \/ Bug = "terminal_is_ack"
 /\ parent.hold /\ child.holds[1]
 /\ (parent.physical /\ child.physical /\ ~parent.ownerHeld /\ ~child.ownerHeld)
       \/ Bug = "ignore_physical"
 /\ release' = [unloaded |-> TRUE, valid |->
       ExactCurrentDisposition(1) /\ parent.physical /\ child.physical /\
       ~parent.ownerHeld /\ ~child.ownerHeld]
 /\ UNCHANGED <<child, parent, attempt, client>>

ReopenOriginal ==
 /\ Bug = "reopen_observer" /\ release.unloaded /\ client.original = "failed"
 /\ client' = [client EXCEPT !.original = "succeeded"]
 /\ UNCHANGED <<child, parent, attempt, release>>

Next == ChildCompletes \/ CommitParent \/ ReadParentProof \/ CloseOriginal
 \/ FinishChildOwner \/ FinishParentOwner \/ ChangeChildEvidence \/ UnloadPair
 \/ ReopenOriginal
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(CommitParent) /\ WF_vars(ReadParentProof)
 /\ WF_vars(CloseOriginal) /\ WF_vars(FinishChildOwner) /\ WF_vars(FinishParentOwner)
 /\ WF_vars(UnloadPair)

TypeOK ==
 /\ \A i \in Children : child.status[i] \in
       {"absent", "active", "suspended", "succeeded", "failed", "cancelled"}
 /\ parent.state \in {"active", "terminal"}
 /\ attempt.phase \in {"ready", "returned"}
 /\ attempt.known \in {"unknown", "pre", "post"}
 /\ child.businessRuns \in 1..2 /\ attempt.commitCount \in 0..1
ExactTerminalAcknowledgement == parent.ackValid
AtomicAcknowledgement == (\E i \in Children : parent.ack[i] # NoReceipt) => parent.state = "terminal"
ImportMeaningPreserved == parent.imported = [i \in Children |-> i = 1 /\ Imported]
HistoryHeld == parent.hold /\ \A i \in Children : child.holds[i]
NoBusinessReplay == child.businessRuns = 1
PairReleaseProof == release.valid
ClosedObservation == client.closed # None => client.original = client.closed
ChildOutcomePreserved == Terminal(child.status[1]) => child.status[1] = Outcome
ParentOutcomePreserved == parent.state = "terminal" => parent.outcome = ParentOutcome
EventuallyAcknowledged == <> (parent.ack[1] # NoReceipt)
EventuallyReleased == <> release.unloaded
EventuallyReadPost == <> (attempt.known = "post")
NoAcknowledgedPendingChildWitness == ~(parent.ack[1] # NoReceipt /\ child.ownerHeld)
NoFailedObserverReleasedWitness == ~(client.original = "failed" /\ release.unloaded)
NoUnimportedAcknowledgementWitness == ~(parent.ack[1] # NoReceipt /\ ~parent.imported[1])
NoActiveSiblingWitness == ~(parent.ack[1] # NoReceipt /\ child.status[2] = "active" /\ parent.ack[2] = NoReceipt)
NoTerminalSiblingWitness == ~(parent.ack[1] # NoReceipt /\ parent.ack[2] # NoReceipt /\ ~parent.imported[2])
NoUnknownPostReleasedWitness == ~(parent.state = "terminal" /\ parent.ack[1] # NoReceipt /\
  attempt.known = "unknown" /\ client.original = "failed" /\ release.unloaded)
NoUnknownPostWitness == ~(parent.state = "terminal" /\ parent.ack[1] # NoReceipt /\ attempt.known = "unknown")
=============================================================================
