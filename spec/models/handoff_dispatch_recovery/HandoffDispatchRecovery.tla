--------------------- MODULE HandoffDispatchRecovery ---------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Save, Readable, RestoreReads, Caller, ExplicitRetry, SettleWorkers,
          StableAuthority, Drift, DriftPhase, Links, RunnerCaller,
          TargetProgress, HistoryAdvanced, RefuseFirst, Bug

VARIABLES durable, route, owner, work, clients, chain, runner, reads
vars == <<durable, route, owner, work, clients, chain, runner, reads>>
Observers == 1..2
DispatchFields == {"revision", "agent", "reservation", "held", "cancelled", "generation"}
InitialRoute == [revision |-> 1, agent |-> 1, reservation |-> 1,
  held |-> TRUE, cancelled |-> FALSE, generation |-> 1,
  turn |-> 1, pending |-> 1, source |-> 0, definition |-> 1,
  context |-> 1, graph |-> TRUE, changed |-> FALSE]

SameDispatchField(field) == route[field] = InitialRoute[field]
ExactDispatchAuthority == \A field \in DispatchFields : SameDispatchField(field)
DispatchGrant == \A field \in DispatchFields : field = Bug \/ SameDispatchField(field)
Fact == IF ~reads THEN "unknown"
        ELSE IF ~DispatchGrant THEN "unknown"
        ELSE IF durable.barrier = "post" THEN "post"
        ELSE IF durable.barrier = "pre" THEN "pre" ELSE "unknown"

TargetFacts == [turn |-> route.turn = 1,
  revision |-> route.revision = chain.leaf, agent |-> route.agent = chain.leaf,
  pending |-> route.pending = chain.leaf,
  source |-> route.source = chain.leaf - 1,
  definition |-> route.definition = 1, context |-> route.context = 1,
  graph |-> route.graph, held |-> route.held,
  cancelled |-> ~route.cancelled, reservation |-> route.reservation = 1,
  generation |-> route.generation = 1]
TargetFields == DOMAIN TargetFacts
ExactTargetAuthority == \A field \in TargetFields : TargetFacts[field]
TargetGrant == \A field \in TargetFields : field = Bug \/
  (Bug = "use_current_target" /\ field = "pending") \/ TargetFacts[field]
(* In this bounded reserved-Target state, routing remains non-stable. Existing
   admission then rechecks this subset, not the full Runner read. Phase drift
   is outside this model; the Ruby pending-ID check is conditional on phase. *)
AdmissionGrant ==
 /\ (Bug = "agent" \/ route.agent = chain.leaf)
 /\ (Bug = "pending" \/ route.pending = runner.chosen)
 /\ (Bug = "cancelled" \/ ~route.cancelled)

Init ==
 /\ durable = [barrier |-> Save, writes |-> 0, validWrites |-> TRUE,
      domainWrites |-> 0]
 /\ route = InitialRoute
 /\ owner = [held |-> TRUE, fact |-> "unknown", everPost |-> FALSE,
      grant |-> FALSE, continuations |-> 0, validContinuation |-> TRUE,
      physicalContinuation |-> TRUE, calls |-> 0, preparations |-> 1, refused |-> FALSE]
 /\ work = [stage |-> "idle", kind |-> "read", originalQuiet |-> FALSE,
      quiet |-> TRUE, result |-> "unknown", grant |-> FALSE, exact |-> FALSE]
 /\ clients = [status |-> [i \in Observers |-> "unused"], cancelled |-> {},
      original |-> "failed", validCustody |-> TRUE]
 /\ chain = [state |-> "blocked", leaf |-> 1, started |-> {1},
      historyHeld |-> TRUE]
 /\ runner = [phase |-> "idle", chosen |-> 0, grant |-> FALSE,
      starts |-> 0, validStarts |-> TRUE, resultTurn |-> 0,
      newTurns |-> 0, returned |-> FALSE]
 /\ reads = Readable

OriginalCompletes ==
 /\ SettleWorkers /\ ~work.originalQuiet
 /\ work' = [work EXCEPT !.originalQuiet = TRUE]
 /\ UNCHANGED <<durable, route, owner, clients, chain, runner, reads>>

RestoreRead ==
 /\ RestoreReads /\ ~reads
 /\ reads' = TRUE
 /\ UNCHANGED <<durable, route, owner, work, clients, chain, runner>>

BeginAttempt ==
 /\ Caller /\ owner.held /\ owner.continuations = 0 /\ ~owner.grant
 /\ work.stage = "idle" /\ (work.originalQuiet \/ Bug = "ignore_physical")
 /\ work' = [work EXCEPT !.stage = "running", !.quiet = FALSE,
      !.kind = IF owner.fact = "pre" /\ ExplicitRetry THEN "retry" ELSE "read"]
 /\ clients' = [clients EXCEPT !.status = [i \in Observers |->
      IF clients.status[i] = "unused" THEN "pending" ELSE clients.status[i]]]
 /\ UNCHANGED <<durable, route, owner, chain, runner, reads>>

ReadOrRetry ==
 /\ work.stage = "running"
 /\ LET fact == IF Bug = "cached_post" /\ owner.everPost THEN "post" ELSE Fact
        grant == IF Bug = "cached_post" /\ owner.everPost THEN TRUE ELSE DispatchGrant
        write == work.kind = "retry" /\ fact = "pre" /\ grant
        post == IF write THEN "post" ELSE fact
    IN /\ durable' = [durable EXCEPT
         !.barrier = IF write THEN "post" ELSE @,
         !.writes = @ + IF write THEN 1 ELSE 0,
         !.validWrites = @ /\ (~write \/ (durable.barrier = "pre" /\ ExactDispatchAuthority /\ work.originalQuiet)),
         !.domainWrites = @ + IF write /\ Bug = "replay_participant" THEN 1 ELSE 0]
       /\ work' = [work EXCEPT !.stage = "recorded", !.result = post,
         !.grant = post = "post" /\ grant,
         !.exact = (durable.barrier = "post" \/ write) /\ ExactDispatchAuthority]
       /\ owner' = [owner EXCEPT
         !.calls = @ + IF write /\ Bug = "replay_business" THEN 1 ELSE 0,
         !.preparations = @ + IF write /\ Bug = "rebuild_proposal" THEN 1 ELSE 0]
 /\ UNCHANGED <<route, clients, chain, runner, reads>>

WorkerCompletes ==
 /\ SettleWorkers /\ work.stage = "recorded" /\ ~work.quiet
 /\ work' = [work EXCEPT !.quiet = TRUE]
 /\ UNCHANGED <<durable, route, owner, clients, chain, runner, reads>>

ReceiveAttempt ==
 /\ work.stage = "recorded" /\ work.quiet
 /\ owner' = [owner EXCEPT
      !.fact = IF owner.everPost THEN "post" ELSE work.result,
      !.everPost = @ \/ work.result = "post", !.grant = work.grant]
 /\ work' = [work EXCEPT !.stage = "idle"]
 /\ clients' = [clients EXCEPT !.status = [i \in Observers |->
      IF clients.status[i] = "pending" THEN "complete" ELSE clients.status[i]],
      !.original = IF Bug = "reopen_original" THEN "complete" ELSE @]
 /\ UNCHANGED <<durable, route, chain, runner, reads>>

RefuseContinuation ==
 /\ RefuseFirst /\ owner.grant /\ ~owner.refused /\ owner.continuations = 0
 /\ owner' = [owner EXCEPT !.grant = FALSE, !.refused = TRUE]
 /\ UNCHANGED <<durable, route, work, clients, chain, runner, reads>>

AdmitContinuation ==
 /\ owner.held /\ owner.continuations = 0 /\ owner.grant
 /\ ~RefuseFirst \/ owner.refused
 /\ work.stage = "idle" /\ work.quiet
 /\ work.originalQuiet \/ Bug = "ignore_physical"
 /\ owner' = [owner EXCEPT !.continuations = 1, !.grant = FALSE,
      !.validContinuation = ExactDispatchAuthority /\ work.exact /\ durable.barrier = "post",
      !.physicalContinuation = work.originalQuiet /\ work.quiet,
      !.calls = @ + 1]
 /\ chain' = [chain EXCEPT !.state = IF Links = 0 THEN "terminal" ELSE "reserved",
      !.leaf = IF Links = 0 THEN 1 ELSE 2]
 /\ route' = IF Links = 0 THEN route ELSE [route EXCEPT
      !.revision = @ + 1, !.agent = 2, !.pending = 2, !.source = 1]
 /\ UNCHANGED <<durable, work, clients, runner, reads>>

ReleaseOwner ==
 /\ owner.held /\ owner.continuations = 1 /\ work.quiet /\ work.originalQuiet
 /\ owner' = [owner EXCEPT !.held = FALSE]
 /\ UNCHANGED <<durable, route, work, clients, chain, runner, reads>>

CancelObserver(i) ==
 /\ i \in Observers /\ clients.status[i] = "pending"
 /\ clients' = [clients EXCEPT !.status[i] = "cancelled", !.cancelled = @ \cup {i},
      !.validCustody = @ /\ Bug # "observer_releases_owner"]
 /\ owner' = IF Bug = "observer_releases_owner" THEN [owner EXCEPT !.held = FALSE] ELSE owner
 /\ chain' = IF Bug = "observer_drops_history" THEN [chain EXCEPT !.historyHeld = FALSE] ELSE chain
 /\ UNCHANGED <<durable, route, work, runner, reads>>

(* The proof transaction is not a durable fence across EventLoop admission. *)
MayDrift == ~StableAuthority \/
  (work.stage # "recorded" /\ ~owner.grant /\ runner.phase # "ready")
DriftAuthority ==
 /\ Drift # "none" /\ ~route.changed
 /\ ((DriftPhase = "dispatch" /\ owner.continuations = 0 /\ MayDrift) \/
     (DriftPhase = "runner" /\ owner.continuations = 1 /\ chain.state = "reserved" /\ MayDrift))
 /\ route' = [route EXCEPT
      !.revision = IF Drift = "revision" THEN 9 ELSE @,
      !.agent = IF Drift = "agent" THEN 9 ELSE @,
      !.reservation = IF Drift = "reservation" THEN 2 ELSE @,
      !.held = IF Drift = "held" THEN FALSE ELSE @,
      !.cancelled = IF Drift = "cancelled" THEN TRUE ELSE @,
      !.generation = IF Drift = "generation" THEN 2 ELSE @,
      !.turn = IF Drift = "turn" THEN 2 ELSE @,
      !.pending = IF Drift = "pending" THEN 9 ELSE @,
      !.source = IF Drift = "source" THEN 9 ELSE @,
      !.definition = IF Drift = "definition" THEN 2 ELSE @,
      !.context = IF Drift = "context" THEN 2 ELSE @,
      !.graph = IF Drift = "graph" THEN FALSE ELSE @,
      !.changed = TRUE]
 /\ UNCHANGED <<durable, owner, work, clients, chain, runner, reads>>

AdvanceUnrelatedTurn ==
 /\ HistoryAdvanced /\ chain.state = "terminal" /\ route.turn = 1
 /\ route' = [route EXCEPT !.turn = 2, !.revision = @ + 1,
      !.pending = 9, !.source = 8]
 /\ UNCHANGED <<durable, owner, work, clients, chain, runner, reads>>

ReportPendingRecovery ==
 /\ RunnerCaller /\ owner.continuations = 0 /\ runner.phase = "idle"
 /\ runner' = [runner EXCEPT !.phase = "pending"]
 /\ UNCHANGED <<durable, route, owner, work, clients, chain, reads>>

ResumeExactChain ==
 /\ RunnerCaller /\ runner.phase \in {"idle", "pending", "follow"}
 /\ owner.continuations = 1 /\ reads
 /\ IF chain.state = "terminal"
      THEN /\ runner' = [runner EXCEPT !.phase = "finished", !.returned = TRUE,
             !.resultTurn = IF Bug = "invoke_terminal" THEN route.turn ELSE 1,
             !.newTurns = @ + IF Bug = "invoke_terminal" THEN 1 ELSE 0]
      ELSE /\ chain.state = "reserved"
           /\ runner' = [runner EXCEPT !.phase = IF TargetGrant THEN "ready" ELSE "blocked",
                !.chosen = IF Bug = "use_current_target" THEN route.pending ELSE chain.leaf,
                !.grant = TargetGrant]
 /\ UNCHANGED <<durable, route, owner, work, clients, chain, reads>>

StartExactTarget ==
 /\ runner.phase = "ready" /\ chain.state = "reserved"
 /\ LET admitted == IF Bug = "cached_target_authority" THEN runner.grant ELSE AdmissionGrant
    IN IF admitted
       THEN /\ chain' = [chain EXCEPT !.state = "active", !.started = @ \cup {runner.chosen}]
            /\ runner' = [runner EXCEPT !.phase = "observing", !.starts = @ + 1,
                 !.validStarts = @ /\ ExactTargetAuthority /\ runner.chosen = chain.leaf]
       ELSE /\ runner' = [runner EXCEPT !.phase = "blocked"]
            /\ UNCHANGED chain
 /\ UNCHANGED <<durable, route, owner, work, clients, reads>>

CompleteTarget ==
 /\ TargetProgress /\ chain.state = "active" /\ runner.phase = "observing"
 /\ IF chain.leaf <= Links
      THEN /\ chain' = [chain EXCEPT !.leaf = @ + 1, !.state = "reserved"]
           /\ route' = [route EXCEPT !.revision = @ + 1,
                !.agent = chain.leaf + 1, !.pending = chain.leaf + 1, !.source = chain.leaf]
      ELSE /\ chain' = [chain EXCEPT !.state = "terminal"]
           /\ UNCHANGED route
 /\ runner' = [runner EXCEPT !.phase = "follow"]
 /\ UNCHANGED <<durable, owner, work, clients, reads>>

DuplicateTarget ==
 /\ Bug = "duplicate_target" /\ runner.phase = "observing" /\ chain.state = "active"
 /\ runner.starts <= 2
 /\ runner' = [runner EXCEPT !.starts = @ + 1]
 /\ UNCHANGED <<durable, route, owner, work, clients, chain, reads>>

Next == OriginalCompletes \/ RestoreRead \/ BeginAttempt \/ ReadOrRetry \/
        WorkerCompletes \/ ReceiveAttempt \/ RefuseContinuation \/ AdmitContinuation \/ ReleaseOwner \/
        (\E i \in Observers : CancelObserver(i)) \/ DriftAuthority \/
        AdvanceUnrelatedTurn \/ ReportPendingRecovery \/ ResumeExactChain \/ StartExactTarget \/
        CompleteTarget \/ DuplicateTarget
Spec == Init /\ [][Next]_vars
ProgressSpec == Spec /\ WF_vars(OriginalCompletes) /\ WF_vars(RestoreRead) /\
  WF_vars(BeginAttempt) /\ WF_vars(ReadOrRetry) /\ WF_vars(WorkerCompletes) /\
  WF_vars(ReceiveAttempt) /\ WF_vars(RefuseContinuation) /\ WF_vars(AdmitContinuation) /\ WF_vars(ReleaseOwner) /\
  WF_vars(ResumeExactChain) /\ WF_vars(StartExactTarget) /\ WF_vars(CompleteTarget)

TypeOK == /\ durable.barrier \in {"pre", "post", "other"}
          /\ owner.fact \in {"unknown", "pre", "post"}
          /\ owner.continuations \in 0..1 /\ chain.leaf \in 1..3
          /\ work.stage \in {"idle", "running", "recorded"}
          /\ runner.phase \in {"idle", "pending", "follow", "ready", "blocked", "observing", "finished"}
          /\ clients.cancelled \subseteq Observers
ExactRetry == durable.validWrites
NoDomainReplay == durable.domainWrites = 0 /\ owner.preparations = 1
NoBusinessReplay == owner.calls = owner.continuations
FreshDispatchAuthority == owner.validContinuation
PhysicalCustody == owner.physicalContinuation /\ clients.validCustody /\
                   (work.stage # "idle" => owner.held /\ work.originalQuiet)
HistoricalPostSticky == owner.everPost => owner.fact = "post"
ClosedOriginal == clients.original = "failed"
IndependentObservers == \A i \in clients.cancelled : clients.status[i] = "cancelled"
HistoryRetained == chain.historyHeld
ExactChainAdmission == runner.validStarts
NoDuplicateTarget == runner.starts <= Cardinality(chain.started) - 1
NoPendingWork == owner.continuations = 0 => runner.starts = 0 /\ runner.newTurns = 0
NoNewTurnOnResume == runner.newTurns = 0
ExactHistoricalResult == runner.returned => runner.resultTurn = 1
EventuallyContinued == <> (owner.continuations = 1)
EventuallyReturned == <>runner.returned
EventuallyReleased == <>~owner.held

NoReadOnlyPostWitness == ~(Save = "post" /\ durable.writes = 0 /\ runner.returned)
NoExplicitRetryWitness == ~(durable.writes = 1 /\ runner.returned)
NoHistoricalReadWitness == ~(route.turn = 2 /\ runner.returned /\ runner.resultTurn = 1)
NoTwoLinkWitness == ~(Links = 2 /\ runner.starts = 2 /\ runner.returned)
NoIndependentObserverWitness == ~(clients.status[1] = "cancelled" /\ clients.status[2] = "complete")
NoRetainedUnknownWitness == ~(~reads /\ owner.held /\ owner.fact = "unknown" /\ work.stage = "idle" /\ clients.status[1] = "complete")
NoBlockedAuthorityWitness == ~(route.changed /\ owner.continuations = 0 /\ owner.held /\ work.stage = "idle" /\ clients.status[1] = "complete")
NoPendingRecoveryWitness == ~(runner.phase = "pending" /\ owner.held /\ owner.continuations = 0)
NoBlockedTargetWitness == ~(route.changed /\ runner.phase = "blocked")
=============================================================================
