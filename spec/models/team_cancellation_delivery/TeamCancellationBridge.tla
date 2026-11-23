-------------------- MODULE TeamCancellationBridge --------------------
EXTENDS Naturals, FiniteSets

CONSTANTS InitialProfile, AllowTerminal, AllowRuntimeChange,
          AllowExplicitRequests, AllowHostAbort, Bug

VARIABLE s

TerminalResults == {"success", "failure"}
ToStale(callbacks) == IF "current" \in callbacks
                      THEN (callbacks \ {"current"}) \cup {"stale"}
                      ELSE callbacks

Init ==
  LET fresh == InitialProfile = "fresh"
      retained == InitialProfile \in {"retained", "retry", "resume_retry", "failed_retry", "draining_retry"}
      waiting == InitialProfile = "waiting_token"
      captured == ~fresh /\ ~waiting
  IN s = [control |-> [reserved |-> ~fresh, open |-> ~fresh /\ ~retained,
                       pending |-> captured, accepted |-> captured,
                       disposition |-> "none", knownDurable |-> FALSE,
                       knownTerminal |-> FALSE],
          host |-> [phase |-> IF fresh THEN "new" ELSE IF retained THEN "returned"
                              ELSE IF waiting THEN "child_wait"
                              ELSE IF InitialProfile = "busy" THEN "busy"
                              ELSE "checkpoint",
                    using |-> ~fresh /\ ~retained,
                    observer |-> IF retained THEN "delivery_error" ELSE "active"],
          attempt |-> [owner |-> "none", phase |-> "none", receipt |-> "none"],
          world |-> [runtime |-> IF InitialProfile = "failed_retry" THEN "failed"
                                ELSE IF InitialProfile = "draining_retry" THEN "draining" ELSE "running",
                    current |-> TRUE,
                    storageReliable |-> InitialProfile \in {"ready", "busy", "retained", "retry", "resume_retry", "failed_retry", "draining_retry", "waiting_token"},
                    job |-> "active", childReady |-> FALSE,
                    cachedIncomplete |-> InitialProfile = "failed_retry"],
          callbacks |-> IF waiting THEN {"current"} ELSE {},
          durableIntent |-> FALSE, childSignal |-> FALSE,
          localCalls |-> 0,
          retryRequest |-> IF InitialProfile \in {"retry", "failed_retry", "draining_retry"}
                           THEN "direct" ELSE IF InitialProfile = "resume_retry"
                           THEN "resume" ELSE "none",
          sawChildWaitWake |-> FALSE, sawCommitLoss |-> FALSE,
          sawDeliveryError |-> retained, staleAccepted |-> FALSE,
          storeOnWrongRuntime |-> FALSE, directObserver |-> "idle",
          concurrentDirectUsed |-> FALSE, sawSuppressedHostFailure |-> FALSE]

Reserve == /\ ~s.control.reserved /\ s.host.phase = "new"
           /\ s.world.current /\ s.world.runtime = "running"
           /\ s' = [s EXCEPT !.control.reserved = TRUE]

(* Slot admission refusal precedes subscription; no cancellation is accepted. *)
RefuseReservation ==
  /\ ~s.control.reserved /\ s.host.phase = "new"
  /\ s' = [s EXCEPT !.host.phase = "returned", !.host.observer = "admission_error"]

Subscribe(alreadyCancelled) ==
  /\ s.host.phase = "new" /\ s.world.current /\ s.world.runtime = "running"
  /\ (s.control.reserved \/ Bug = "subscribe_before_reserve")
  /\ s' = [s EXCEPT !.control.open = TRUE,
                    !.control.pending = alreadyCancelled,
                    !.control.accepted = alreadyCancelled,
                    !.host.phase = "checkpoint", !.host.using = TRUE]

CaptureTokenCallback ==
  /\ s.control.open /\ "current" \notin s.callbacks
  /\ s' = [s EXCEPT !.callbacks = @ \cup {"current"}]

DeliverCurrentCallback ==
  /\ s.control.open /\ "current" \in s.callbacks
  /\ s' = [s EXCEPT !.callbacks = @ \ {"current"},
       !.control.accepted = TRUE,
       !.control.pending = IF s.control.disposition = "none" THEN TRUE ELSE @,
       !.host.phase = IF s.host.phase = "child_wait" /\ Bug # "lost_wake"
                       THEN "checkpoint" ELSE @,
       !.sawChildWaitWake = @ \/ s.host.phase = "child_wait"]

DeliverStaleCallback ==
  /\ "stale" \in s.callbacks
  /\ s' = [s EXCEPT !.callbacks = @ \ {"stale"},
       !.control.accepted = IF Bug = "accept_stale_callback" THEN TRUE ELSE @,
       !.control.pending = IF Bug = "accept_stale_callback" THEN TRUE ELSE @,
       !.staleAccepted = @ \/ Bug = "accept_stale_callback"]

EnterChildWait ==
  /\ s.host.phase = "checkpoint" /\ s.attempt.owner = "none"
  /\ ~s.world.childReady
  /\ (~s.control.pending \/ Bug = "wait_ignores_latch")
  /\ s' = [s EXCEPT !.host.phase = "child_wait"]

EnterBusySegment ==
  /\ s.host.phase = "checkpoint" /\ ~s.control.pending
  /\ s.attempt.owner = "none"
  /\ s' = [s EXCEPT !.host.phase = "busy"]

(* Actual return of user code, not CPU allocation or preemption. *)
ReturnFromBusySegment ==
  /\ s.host.phase = "busy"
  /\ s' = [s EXCEPT !.host.phase = "checkpoint"]

BeginAttempt(owner) ==
  /\ s.control.pending /\ s.control.reserved
  /\ (s.attempt.owner = "none" \/ Bug = "overlap")
  /\ (s.world.current \/ Bug = "wrong_runtime")
  /\ (owner = "host" => s.host.using /\ s.host.phase = "checkpoint")
  /\ (owner = "direct" => s.retryRequest = "direct")
  /\ ~(Bug = "retry_self_reject" /\ owner = "direct" /\ s.control.reserved)
  /\ s' = [s EXCEPT !.attempt = [owner |-> owner, phase |-> "store", receipt |-> "none"],
       !.localCalls = @ + 1,
       !.host.phase = IF owner = "host" THEN "sync_call" ELSE @,
       !.retryRequest = IF owner = "direct" THEN "none" ELSE @,
       !.directObserver = IF owner = "direct" THEN "active" ELSE @,
       !.storeOnWrongRuntime = @ \/ ~s.world.current]

BeginHostAttempt == BeginAttempt("host")
BeginDirectAttempt == BeginAttempt("direct")

KnownTerminal ==
  /\ s.attempt.phase = "store"
  /\ s.world.job \in TerminalResults
  /\ s' = [s EXCEPT !.attempt.phase = "signal", !.attempt.receipt = "terminal",
                    !.control.knownTerminal = TRUE]

CommitKnown ==
  /\ s.attempt.phase = "store"
  /\ s.world.job = "active"
  /\ s' = [s EXCEPT !.durableIntent = TRUE, !.control.knownDurable = TRUE,
                    !.attempt.phase = "signal", !.attempt.receipt = "confirmed"]

CommitResponseLost ==
  /\ s.attempt.phase = "store" /\ ~s.world.storageReliable
  /\ s.world.job = "active"
  /\ s' = [s EXCEPT !.durableIntent = TRUE, !.attempt.phase = "readback",
                    !.attempt.receipt = "unknown", !.sawCommitLoss = TRUE]

WriteFailedOrUnknown ==
  /\ s.attempt.phase = "store" /\ ~s.world.storageReliable
  /\ s' = [s EXCEPT !.attempt.phase = "readback", !.attempt.receipt = "unknown"]

ReadbackKnown ==
  /\ s.attempt.phase = "readback"
  /\ s.durableIntent
  /\ s' = [s EXCEPT !.control.knownDurable = TRUE,
                    !.attempt.phase = "signal", !.attempt.receipt = "confirmed"]

ReadbackTerminal ==
  /\ s.attempt.phase = "readback"
  /\ ~s.durableIntent /\ s.world.job \in TerminalResults
  /\ s' = [s EXCEPT !.control.knownTerminal = TRUE,
                    !.attempt.phase = "signal", !.attempt.receipt = "terminal"]

ReadbackUnresolved ==
  /\ s.attempt.phase = "readback"
  /\ (~s.world.storageReliable \/ (~s.durableIntent /\ s.world.job = "active"))
  /\ s' = [s EXCEPT !.attempt.phase = "return", !.attempt.receipt = "error"]

SignalChild ==
  /\ (s.attempt.phase = "signal"
      \/ (Bug = "early_signal" /\ s.control.pending))
  /\ s' = [s EXCEPT !.childSignal = TRUE,
                    !.attempt.phase = IF s.attempt.owner = "none" THEN @ ELSE "return"]

FinishSuccessfulAttempt ==
  /\ s.attempt.phase = "return"
  /\ s.attempt.receipt \in {"confirmed", "terminal"}
  /\ (s.attempt.receipt = "confirmed" => s.childSignal)
  /\ s' = [s EXCEPT !.control.pending = FALSE,
       !.control.disposition = IF @ = "none" THEN s.attempt.receipt ELSE @,
       !.host.phase = IF s.attempt.owner = "host" THEN "checkpoint" ELSE @,
       !.attempt = [owner |-> "none", phase |-> "none", receipt |-> "none"],
       !.directObserver = IF s.attempt.owner = "direct" THEN "success" ELSE @,
       !.localCalls = @ - 1]

FinishFailedAttempt ==
  /\ s.attempt.phase = "return" /\ s.attempt.receipt = "error"
  /\ s' = [s EXCEPT
       !.control.pending = IF Bug = "drop_on_error" THEN FALSE ELSE @,
       !.control.open = IF s.attempt.owner = "host" /\ s.control.pending THEN FALSE ELSE @,
       !.host.phase = IF s.attempt.owner = "host"
                      THEN IF s.control.pending THEN "returned" ELSE "checkpoint" ELSE @,
       !.host.using = IF s.attempt.owner = "host" /\ s.control.pending THEN FALSE ELSE @,
       !.host.observer = IF s.attempt.owner = "host" /\ s.control.pending THEN "delivery_error" ELSE @,
       !.sawDeliveryError = @ \/ s.control.pending,
       !.directObserver = IF s.attempt.owner = "direct" THEN "error" ELSE @,
       !.sawSuppressedHostFailure = @ \/ (s.attempt.owner = "host" /\ ~s.control.pending),
       !.callbacks = IF s.attempt.owner = "host" /\ s.control.pending THEN ToStale(@) ELSE @,
       !.attempt = [owner |-> "none", phase |-> "none", receipt |-> "none"],
       !.localCalls = @ - 1]

(* One concurrent direct call is abstracted at its authoritative linearization
   and notification. It is not serialized behind the paused host call. *)
ConcurrentDirectConfirmation ==
  /\ AllowExplicitRequests /\ s.host.using /\ s.attempt.owner = "host"
  /\ s.control.pending /\ s.world.current /\ ~s.concurrentDirectUsed
  /\ s' = [s EXCEPT !.durableIntent = @ \/ s.world.job = "active",
       !.control.knownDurable = @ \/ s.world.job = "active",
       !.control.knownTerminal = @ \/ s.world.job \in TerminalResults,
       !.control.pending = FALSE,
       !.control.disposition = IF s.world.job = "active" THEN "confirmed" ELSE "terminal",
       !.childSignal = TRUE, !.directObserver = "success", !.concurrentDirectUsed = TRUE]

ConcurrentDirectFailure ==
  /\ AllowExplicitRequests /\ s.host.using /\ s.attempt.owner = "host"
  /\ s.world.current /\ ~s.world.storageReliable /\ ~s.concurrentDirectUsed
  /\ s' = [s EXCEPT !.directObserver = "error", !.concurrentDirectUsed = TRUE]

HostReturnsOrRaises ==
  /\ s.host.phase \in {"checkpoint", "busy"}
  /\ s.attempt.owner = "none"
  /\ ((~s.control.pending /\ s.world.job \in TerminalResults)
       \/ (AllowHostAbort /\ s.host.phase = "busy"))
  /\ s' = [s EXCEPT !.host.phase = "returned", !.host.using = FALSE,
       !.host.observer = IF s.control.pending THEN "business_error" ELSE "returned",
       !.control.open = FALSE, !.callbacks = ToStale(@),
       !.control.pending = IF Bug = "drop_on_close" THEN FALSE ELSE @]

ReleaseAdmission ==
  /\ s.control.reserved /\ ~s.host.using /\ ~s.control.open
  /\ ((~s.control.pending /\ s.localCalls = 0) \/ Bug = "early_release")
  /\ s' = [s EXCEPT !.control.reserved = FALSE]

SupplyExplicitRetry(kind) ==
  /\ AllowExplicitRequests /\ s.control.pending /\ s.retryRequest = "none"
  /\ kind \in {"direct", "resume"}
  /\ s' = [s EXCEPT !.retryRequest = kind]

(* Resume requires ordinary admission in the current running Runtime. Direct
   cancel instead needs no new executor admission and may run when it failed. *)
ExplicitResume ==
  /\ s.retryRequest = "resume" /\ s.control.pending /\ ~s.host.using
  /\ s.attempt.owner = "none" /\ s.world.current /\ s.world.runtime = "running"
  /\ ~(Bug = "retry_self_reject" /\ s.control.reserved)
  /\ s' = [s EXCEPT !.host.using = TRUE, !.host.phase = "checkpoint",
       !.host.observer = "active", !.control.open = TRUE,
       !.retryRequest = "none", !.callbacks = ToStale(@)]

RecoverStorage ==
  /\ ~s.world.storageReliable
  /\ s' = [s EXCEPT !.world.storageReliable = TRUE]

CompleteBusiness(result) ==
  /\ AllowTerminal /\ s.world.job = "active" /\ result \in TerminalResults
  /\ s' = [s EXCEPT !.world.job = result, !.world.childReady = TRUE,
       !.host.phase = IF s.host.phase = "child_wait" THEN "checkpoint" ELSE @]

FailRuntime ==
  /\ AllowRuntimeChange /\ s.world.runtime # "failed"
  /\ s' = [s EXCEPT !.world.runtime = "failed",
       !.world.cachedIncomplete = s.control.reserved \/ s.localCalls > 0]

BeginDraining ==
  /\ AllowRuntimeChange /\ s.world.runtime = "running"
  /\ s' = [s EXCEPT !.world.runtime = "draining"]

ReplaceDefault ==
  /\ AllowRuntimeChange /\ s.world.current
  /\ s' = [s EXCEPT !.world.current = FALSE]

Next == Reserve \/ RefuseReservation \/ (\E b \in BOOLEAN : Subscribe(b))
        \/ CaptureTokenCallback \/ DeliverCurrentCallback \/ DeliverStaleCallback
        \/ EnterChildWait \/ EnterBusySegment \/ ReturnFromBusySegment
        \/ BeginHostAttempt \/ BeginDirectAttempt
        \/ KnownTerminal \/ CommitKnown \/ CommitResponseLost \/ WriteFailedOrUnknown
        \/ ReadbackKnown \/ ReadbackTerminal \/ ReadbackUnresolved \/ SignalChild
        \/ FinishSuccessfulAttempt \/ FinishFailedAttempt
        \/ ConcurrentDirectConfirmation \/ ConcurrentDirectFailure
        \/ HostReturnsOrRaises \/ ReleaseAdmission
        \/ (\E kind \in {"direct", "resume"} : SupplyExplicitRetry(kind))
        \/ ExplicitResume \/ RecoverStorage
        \/ (\E result \in TerminalResults : CompleteBusiness(result))
        \/ BeginDraining \/ FailRuntime \/ ReplaceDefault

Spec == Init /\ [][Next]_s

DomainCallProgress == KnownTerminal \/ CommitKnown \/ CommitResponseLost
                      \/ WriteFailedOrUnknown \/ ReadbackKnown \/ ReadbackTerminal
                      \/ ReadbackUnresolved \/ SignalChild
                      \/ FinishSuccessfulAttempt \/ FinishFailedAttempt
LocalProgress == WF_s(BeginHostAttempt) /\ WF_s(BeginDirectAttempt)
                 /\ WF_s(ExplicitResume) /\ WF_s(DomainCallProgress)
ProgressSpec == Spec /\ LocalProgress
CooperativeSpec == ProgressSpec /\ WF_s(ReturnFromBusySegment)
WakingSpec == ProgressSpec /\ WF_s(DeliverCurrentCallback)
NoHostProgressSpec == Spec /\ WF_s(DomainCallProgress)
NoCallProgressSpec == Spec /\ WF_s(BeginHostAttempt)
                      /\ WF_s(BeginDirectAttempt) /\ WF_s(ExplicitResume)

TypeOK ==
  /\ s.control \in [reserved : BOOLEAN, open : BOOLEAN, pending : BOOLEAN,
       accepted : BOOLEAN, disposition : {"none", "confirmed", "terminal"},
       knownDurable : BOOLEAN, knownTerminal : BOOLEAN]
  /\ s.host \in [phase : {"new", "checkpoint", "child_wait", "busy", "sync_call", "returned"},
       using : BOOLEAN, observer : {"active", "delivery_error", "business_error", "returned", "admission_error"}]
  /\ s.attempt \in [owner : {"none", "host", "direct"},
       phase : {"none", "store", "readback", "signal", "return"},
       receipt : {"none", "unknown", "confirmed", "terminal", "error"}]
  /\ s.world \in [runtime : {"running", "draining", "failed"}, current : BOOLEAN,
       storageReliable : BOOLEAN, job : {"active"} \cup TerminalResults,
       childReady : BOOLEAN, cachedIncomplete : BOOLEAN]
  /\ s.callbacks \subseteq {"current", "stale"}
  /\ s.localCalls \in 0..2 /\ s.retryRequest \in {"none", "direct", "resume"}
  /\ s.directObserver \in {"idle", "active", "success", "error"}
  /\ \A key \in {"durableIntent", "childSignal", "sawChildWaitWake", "sawCommitLoss",
                  "sawDeliveryError", "staleAccepted", "storeOnWrongRuntime",
                  "concurrentDirectUsed", "sawSuppressedHostFailure"} : s[key] \in BOOLEAN

ReservedBeforeSubscription == s.control.open => s.control.reserved
AcceptedIntentNotLost == s.control.accepted =>
                        (s.control.pending \/ s.control.disposition # "none")
PendingAdmissionRetained == s.control.pending => s.control.reserved
TrackedCallAdmissionHeld == s.localCalls > 0 => s.control.reserved
NoTrackedCallOverlap == s.localCalls <= 1
SignalHasEvidence == s.childSignal =>
  ((s.durableIntent /\ s.control.knownDurable)
   \/ (s.world.job \in TerminalResults /\ s.control.knownTerminal))
DispositionSound ==
  /\ (s.control.disposition = "confirmed" =>
        s.durableIntent /\ s.control.knownDurable /\ s.childSignal)
  /\ (s.control.disposition = "terminal" =>
        s.world.job \in TerminalResults /\ s.control.knownTerminal)
NoStaleCallbackAcceptance == ~s.staleAccepted
CurrentAtCallAdmission == ~s.storeOnWrongRuntime
TerminalStable == [][s.world.job \in TerminalResults => s'.world.job = s.world.job]_s
ShutdownReportStable == [][s.world.cachedIncomplete => s'.world.cachedIncomplete]_s

PendingEventuallyDisposed == s.control.pending ~> (s.control.disposition # "none")

NoCommitLossErrorWitness == ~(s.sawCommitLoss /\ s.sawDeliveryError /\
                             s.control.pending /\ s.control.reserved)
NoChildWaitWakeWitness == ~(s.sawChildWaitWake /\ s.childSignal /\ ~s.world.childReady)
NoTerminalNoopWitness == ~(s.control.disposition = "terminal" /\ ~s.durableIntent)
NoCancelThenSuccessWitness == ~(s.childSignal /\ s.world.job = "success")
NoFailedRuntimeRetryWitness == ~(s.world.runtime = "failed" /\
    s.control.disposition = "confirmed" /\ s.world.cachedIncomplete)
NoObserverErrorRetentionWitness == ~(s.host.observer = "delivery_error" /\
    ~s.host.using /\ s.control.pending /\ s.control.reserved)
NoConcurrentConfirmationWitness == ~(s.concurrentDirectUsed /\ s.sawSuppressedHostFailure
    /\ s.control.disposition # "none" /\ ~s.control.pending /\ s.host.using)
NoDirectFailureIsolationWitness == ~(s.concurrentDirectUsed /\ s.directObserver = "error"
    /\ s.host.observer = "active" /\ s.host.using /\ s.control.pending)

=============================================================================
