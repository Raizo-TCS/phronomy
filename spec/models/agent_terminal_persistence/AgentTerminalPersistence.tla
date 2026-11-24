----------------------- MODULE AgentTerminalPersistence -----------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Profile, TerminalKind, CapturedCancellation, AllowReads, AllowRetries,
          AllowInterference, AllowReadFailure, AllowRollback, AllowLostReply,
          ForceLostReply, AllowReadRecovery, Outermost, MaxRetryCalls, Bug

VARIABLE s

Before == [root |-> "active_root", execution |-> "active_execution",
           journal |-> "empty_suffix", cancellation |-> CapturedCancellation]
After == [root |-> "idle_root", execution |-> TerminalKind,
          journal |-> "captured_ids_and_sequences", cancellation |-> CapturedCancellation]
AbsentContent == [ref |-> "absent", bytes |-> "absent", version |-> "absent"]
Content == [ref |-> "captured_ref", bytes |-> "captured_bytes", version |-> "captured_version"]
WrongContent == [ref |-> "captured_ref", bytes |-> "different_bytes", version |-> "captured_version"]
WrongRef == [ref |-> "different_ref", bytes |-> "captured_bytes", version |-> "captured_version"]
Fields == {"root", "execution", "journal", "cancellation"}
Changed(row, field) == IF field = "cancellation"
                         THEN [row EXCEPT !.cancellation = ~@]
                         ELSE [row EXCEPT ![field] = "different"]
FullPre(row) == row = Before
ContentMatches(blob) == blob.ref = Content.ref /\ blob.bytes = Content.bytes
FullPost(row, blob) == row = After /\ ContentMatches(blob)

Matches(row, wanted) ==
  IF Bug = "execution_only" THEN row.execution = wanted.execution
  ELSE IF Bug = "ignore_cancellation"
       THEN [row EXCEPT !.cancellation = wanted.cancellation] = wanted
       ELSE row = wanted

Classify(row, blob, readable, settled) ==
  IF ~readable THEN "unknown"
  ELSE IF Matches(row, After) /\ (ContentMatches(blob) \/ Bug = "ignore_content")
       THEN "committed"
  ELSE IF Matches(row, Before) /\ (settled \/ Bug = "local_return_is_settlement")
       THEN "not_committed"
       ELSE "unknown"

InitialRows ==
  CASE Profile = "post" \/ Profile = "post_missing_content" -> After
    [] Profile = "post_root_mismatch" -> Changed(After, "root")
    [] Profile = "post_journal_mismatch" -> Changed(After, "journal")
    [] Profile = "post_cancellation_mismatch" -> Changed(After, "cancellation")
    [] Profile = "pre_cancellation_mismatch" -> Changed(Before, "cancellation")
    [] OTHER -> Before

InitialBlob == IF Profile \in {"post", "post_root_mismatch", "post_journal_mismatch",
                               "post_cancellation_mismatch", "shared_pre"}
                 THEN Content ELSE AbsentContent

Init ==
  s = [rows |-> InitialRows, blob |-> InitialBlob, baseBlob |-> "preexisting_shared_content",
       settled |-> Profile # "pending", readable |-> Profile # "unreadable",
       capturedBefore |-> Before, capturedAfter |-> After,
       capturedContent |-> IF Bug = "missing_content_capture" THEN AbsentContent ELSE Content,
       phase |-> "idle", lockHeld |-> FALSE, retryCalls |-> 0, readCalls |-> 0,
       retryCommits |-> 0, originalCommits |-> IF InitialRows.execution = TerminalKind THEN 1 ELSE 0,
       rollbacks |-> 0, lostReply |-> FALSE, recheckedLostReply |-> FALSE,
       txBefore |-> Before, txBlobBefore |-> AbsentContent, txRows |-> After,
       txContent |-> AbsentContent, txCommitted |-> FALSE,
       lastCommittedRows |-> Before, lastCommittedContent |-> AbsentContent,
       lastDisposition |-> "unknown", observedRows |-> Before, observedBlob |-> AbsentContent,
       observedSettled |-> FALSE, lastCall |-> "none",
       interfered |-> FALSE, readFailed |-> FALSE, readRecovered |-> FALSE,
       capturedComputations |-> 1, providerCalls |-> 1, toolCalls |-> 1, parserCalls |-> 1,
       badGuard |-> FALSE, overwroteChange |-> FALSE, wroteAfterPost |-> FALSE,
       rollbackCorrupted |-> FALSE, readWrote |-> FALSE, publishedUncommitted |-> FALSE]

(* This is backend settlement, not merely local worker or TaskResult return. *)
SettleOriginalPre ==
  /\ ~s.settled /\ s.phase = "idle"
  /\ s' = [s EXCEPT !.settled = TRUE]

SettleOriginalPost ==
  /\ ~s.settled /\ s.phase = "idle"
  /\ s' = [s EXCEPT !.settled = TRUE, !.rows = After, !.blob = Content,
                    !.originalCommits = @ + 1]

(* An external actor has one change; the shared guard excludes it during retry. *)
Interfere(field) ==
  /\ AllowInterference /\ ~s.interfered /\ ~s.lockHeld /\ s.settled
  /\ field \in Fields
  /\ (field # "cancellation" \/ (s.rows.execution = "active_execution" /\ ~s.rows.cancellation))
  /\ s' = [s EXCEPT !.rows = Changed(@, field), !.interfered = TRUE]

ReadUnavailable ==
  /\ AllowReadFailure /\ ~s.readFailed /\ s.readable
  /\ s' = [s EXCEPT !.readable = FALSE, !.readFailed = TRUE]

ReadAvailable ==
  /\ AllowReadRecovery /\ ~s.readable /\ ~s.readRecovered
  /\ s' = [s EXCEPT !.readable = TRUE, !.readRecovered = TRUE]

(* Comparison can be rescue readback or a later call; no automatic write retry is added. *)
Reconcile ==
  /\ AllowReads /\ s.phase = "idle" /\ s.readCalls < 2
  /\ (Profile # "lost_retry" \/ s.lostReply)
  /\ LET result == IF Outermost THEN Classify(s.rows, s.blob, s.readable, s.settled) ELSE "unknown"
     IN s' = [s EXCEPT !.readCalls = @ + 1, !.lastDisposition = result,
          !.observedRows = s.rows, !.observedBlob = s.blob, !.observedSettled = s.settled,
          !.lastCall = "reconcile", !.recheckedLostReply = @ \/ (s.lostReply /\ result = "committed"),
          !.readWrote = @ \/ Bug = "reconcile_writes"]

(* The complete comparison and staging share one outer guarded transaction.
   A post-state call returns without staging any write. *)
BeginRetry ==
  /\ AllowRetries /\ s.phase = "idle" /\ s.retryCalls < MaxRetryCalls
  /\ LET result == IF Outermost THEN Classify(s.rows, s.blob, s.readable, s.settled) ELSE "unknown"
         stage == result = "not_committed" \/ (result = "committed" /\ Bug = "rewrite_post")
         candidate == IF Bug = "regenerate_journal" THEN [After EXCEPT !.journal = "different"] ELSE s.capturedAfter
         material == IF Bug = "change_content_reference" THEN WrongRef ELSE s.capturedContent
     IN s' = [s EXCEPT !.retryCalls = @ + 1, !.lastCall = "retry",
          !.lastDisposition = IF stage THEN "unknown" ELSE result,
          !.observedRows = s.rows, !.observedBlob = s.blob, !.observedSettled = s.settled,
          !.phase = IF stage THEN "staged" ELSE "idle",
          !.lockHeld = stage /\ Bug # "check_then_write",
          !.txBefore = s.rows, !.txBlobBefore = s.blob,
          !.txRows = candidate, !.txContent = material,
          !.badGuard = @ \/ (stage /\ (~FullPre(s.rows) \/ ~s.settled \/ ~Outermost)),
          !.wroteAfterPost = @ \/ (stage /\ result = "committed"),
          !.providerCalls = @ + IF stage /\ Bug = "replay_business" THEN 1 ELSE 0,
          !.toolCalls = @ + IF stage /\ Bug = "replay_business" THEN 1 ELSE 0,
          !.parserCalls = @ + IF stage /\ Bug = "replay_business" THEN 1 ELSE 0,
          !.capturedComputations = @ + IF stage /\ Bug = "regenerate_journal" THEN 1 ELSE 0,
          !.publishedUncommitted = @ \/ (stage /\ Bug = "publish_before_commit")]

CommitRetry ==
  /\ s.phase = "staged"
  /\ s' = [s EXCEPT !.rows = s.txRows, !.blob = s.txContent,
       !.retryCommits = @ + 1, !.lastCommittedRows = s.txRows,
       !.lastCommittedContent = s.txContent, !.txCommitted = TRUE,
       !.overwroteChange = @ \/ s.rows # s.txBefore,
       !.phase = "reply", !.lockHeld = FALSE]

RollbackRetry ==
  /\ AllowRollback /\ s.phase = "staged"
  /\ s' = [s EXCEPT !.phase = "reply", !.lockHeld = FALSE, !.txCommitted = FALSE,
       !.rollbacks = @ + 1,
       !.blob = IF Bug = "rollback_leaks_blob" THEN s.txContent
                ELSE IF Bug = "rollback_deletes_shared_blob" THEN AbsentContent ELSE @,
       !.rollbackCorrupted = @ \/ Bug = "rollback_leaks_blob"
                \/ (Bug = "rollback_deletes_shared_blob" /\ s.txBlobBefore # AbsentContent)]

DeliverRetryReply ==
  /\ s.phase = "reply" /\ ~ForceLostReply
  /\ s' = [s EXCEPT !.phase = "idle", !.lastDisposition = IF s.txCommitted THEN "committed" ELSE "not_committed",
       !.observedRows = IF s.txCommitted THEN s.txRows ELSE s.txBefore,
       !.observedBlob = IF s.txCommitted THEN s.txContent ELSE s.txBlobBefore,
       !.observedSettled = s.settled]

LoseRetryReply ==
  /\ s.phase = "reply" /\ AllowLostReply
  /\ s' = [s EXCEPT !.phase = "idle", !.lastDisposition = "unknown", !.lostReply = TRUE]

Next == SettleOriginalPre \/ SettleOriginalPost
        \/ (\E field \in Fields : Interfere(field))
        \/ ReadUnavailable \/ ReadAvailable \/ Reconcile \/ BeginRetry
        \/ CommitRetry \/ RollbackRetry \/ DeliverRetryReply \/ LoseRetryReply

Spec == Init /\ [][Next]_s
ReadProgressSpec == Spec /\ WF_s(Reconcile)
RetryProgressSpec == Spec /\ WF_s(BeginRetry) /\ WF_s(CommitRetry) /\ WF_s(DeliverRetryReply)
LostReplyProgressSpec == Spec /\ WF_s(BeginRetry) /\ WF_s(CommitRetry)
                             /\ WF_s(LoseRetryReply) /\ WF_s(Reconcile)

TypeOK ==
  /\ s.phase \in {"idle", "staged", "reply"}
  /\ s.lastDisposition \in {"committed", "not_committed", "unknown"}
  /\ s.retryCalls \in 0..MaxRetryCalls /\ s.readCalls \in 0..2
  /\ s.retryCommits \in 0..MaxRetryCalls /\ s.rollbacks \in 0..MaxRetryCalls
  /\ s.originalCommits \in 0..1
  /\ s.blob \in {AbsentContent, Content, WrongContent, WrongRef}
  /\ s.capturedBefore = Before /\ s.capturedAfter = After
  /\ s.settled \in BOOLEAN /\ s.lockHeld \in BOOLEAN

ObservationProofSound ==
  /\ (s.lastDisposition = "committed" => FullPost(s.observedRows, s.observedBlob))
  /\ (s.lastDisposition = "not_committed" => FullPre(s.observedRows) /\ s.observedSettled)
ExactPreGuard == ~s.badGuard
NoConcurrentOverwrite == ~s.overwroteChange
PostDoesNotWrite == ~s.wroteAfterPost
ExactRetryMaterial == s.retryCommits > 0 => s.lastCommittedRows = After /\ s.lastCommittedContent = Content
AtMostOneTerminalCommit == s.originalCommits + s.retryCommits <= 1
RollbackPreservesDurableContent == ~s.rollbackCorrupted /\ s.baseBlob = "preexisting_shared_content"
ReconciliationReadOnly == ~s.readWrote
NoBusinessReplay == s.providerCalls = 1 /\ s.toolCalls = 1 /\ s.parserCalls = 1
ProposalComputedOnce == s.capturedComputations = 1
OnlyOuterCommitPublishes == ~s.publishedUncommitted

EventuallyCommitted == <>(s.lastDisposition = "committed")
EventuallyRecheckedLostReply == <>s.recheckedLostReply

WitnessNoPreRetry == ~(s.retryCommits = 1 /\ s.lastDisposition = "committed" /\ s.originalCommits = 0)
WitnessNoPostNoWrite == ~(s.lastDisposition = "committed" /\ s.retryCalls > 0 /\ s.retryCommits = 0)
WitnessNoRollbackRetry == ~(s.rollbacks > 0 /\ s.retryCommits = 1 /\ s.lastDisposition = "committed")
WitnessNoLostReplyRecheck == ~s.recheckedLostReply
WitnessNoConflictRefusal == ~(s.lastCall = "retry" /\ s.interfered /\ s.phase = "idle" /\ s.lastDisposition = "unknown" /\ s.retryCommits = 0)
WitnessNoCancellationRefusal == ~(s.lastCall = "retry" /\ s.rows.cancellation # CapturedCancellation /\ s.lastDisposition = "unknown" /\ s.retryCommits = 0)
WitnessNoUnreadable == ~(s.lastCall = "reconcile" /\ ~s.readable /\ s.lastDisposition = "unknown")
WitnessNoMissingContent == ~(s.lastCall = "reconcile" /\ s.rows = After /\ s.blob = AbsentContent /\ s.lastDisposition = "unknown")
WitnessNoNestedRefusal == ~(~Outermost /\ s.retryCalls > 0 /\ s.phase = "idle" /\ s.retryCommits = 0 /\ s.lastDisposition = "unknown")
WitnessNoSharedBlobRollback == ~(s.rollbacks > 0 /\ s.retryCommits = 0 /\ s.blob = Content /\ s.rows = Before)
=============================================================================
