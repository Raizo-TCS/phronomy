# Publish retained outcomes from captured persistence facts

Agent owns the observation of an accepted execution result. Persistence owns the encoded facts accepted by the save, and MultiAgent owns the native relationships associated with that execution. A recovered result must agree with the captured persistence facts even when the original application objects later change or become unusable. G3j repairs this publication boundary within the existing owners.

For example, a report service saves `Report completed`, loses the save response, and then changes the original output String. A recovered report must still say `Report completed`. If the report instead failed and its original exception can no longer produce a diagnostic, the already captured failure must remain observable.

This document compares applied G3i `a6c026aaa02b069a330662d67e906c9b6204f6d0` with the G3j candidate. Contract concept v55 and foundation v48 define the responsibility boundaries. The preceding [native preparation account](native-outcome-preparation.md) and [native recovery protocol](native-parent-outcome-recovery.md) remain the public protocol references. G3j adds no public API, durable owner, participant callback or preparation-retry permission. Candidate validation evidence accompanies the delivered change; this document does not certify arbitrary production backends.

## Captured facts and publication responsibility

The original outcome worker already captures the content and record values required for an exact save. That worker now also derives a detached terminal observation from those captured bytes. The EventLoop publishes that observation after the existing owner and persistence checks, without reading the Store or invoking the original output or exception again.

For example, a saved plain report uses captured text content, a structured report uses captured JSON plus its captured raw output, and a failed report uses the exact captured error JSON. An output-contract failure keeps its schema digest, reason, violations and raw output because those fields belong to its saved diagnostic.

| Value or responsibility | Authoritative source | Boundary |
| --- | --- | --- |
| Completed result | Captured content addressed by `result_ref`, decoded using the recorded result format. | A later mutation or application conversion cannot replace the saved result. |
| Structured raw output | Captured text addressed by `raw_output_ref`. | Parsing and validation are not repeated during publication. |
| Failed result | Captured JSON addressed by `error_ref`. | Keep the complete `OutputError` or ordinary business diagnostic; do not call `message`, `cause` or `diagnostic` again. |
| Local execution application | Existing semantic outcome and owner checks. | Domain transitions, journal application and original exception delivery retain their existing responsibilities. |
| Save confirmation and retry | Exact captured pre/post comparison, physical settlement, Store identity and current native authority. | An observation cache neither proves a write committed nor grants permission to retry it. |
| Native waits | Existing coordination-wait or approval-wait representation. | A captured wait remains unfinished work and does not acquire a terminal observation. |

`TerminalPersistenceEvidence` derives the terminal `ExecutionObservation` while the original worker prepares complete evidence. Its private captured-content adapter reads only retained `ContentWrite` bytes through the existing content decoding rules. `OutcomeRecoveryOperation#remember_post` selects that prepared observation; the inherited terminal recovery path shares this rule. Missing captured content fails evidence construction instead of falling back to a live application object. The original semantic outcome remains available for ordinary delivery and local state application. This does not move standalone physical writes before or after their existing evidence boundary; native preparation retains its G3i ordering.

This is a correction to a narrower G3i guarantee: retaining detached proof input avoided repeated proof construction callbacks, but did not ensure that later owner publication used the same detached facts. The coordinator application path does not itself rebuild a business diagnostic; the repeated access was in owner observation construction.

## Application scenario and behavioral contract

The report application owns whether to permit a persistence-only retry and how long to retain unresolved responsibility. The framework owns faithful observation of the saved result and must not require the application to reconstruct its own diagnostic or guess whether business work should run again.

For example, the parent receives `Prepare one report`, makes one offline Provider call, and returns a filtered text report or the original business error. A declared reviewer selects the native coordinator, but this bounded example does not dispatch that reviewer or execute a Tool. The fault fixture changes the caller-owned output or disables the original error accessor after complete evidence capture, then optionally loses a rolled-back or committed save response.

| Aspect | Contract shared by both application versions |
| --- | --- |
| Input and ordinary output | One request produces `Report completed`, or one `G3jReportError` with code `report.source_unavailable`. |
| Errors | Ordinary failure preserves the original business exception object. An ambiguous save creates the existing `OutcomeRecoveryError`; later observation cannot reopen the original failed task. |
| Ordering and concurrency | One admitted execution and one Provider call. Reconciliation follows the original failed observation; explicit captured-write retry follows confirmed pre-state only. |
| Persistence | Actual in-memory Persistence and Runtime. The fixture intercepts the real outer transaction; it does not replace exact readback or replay logic. |
| Ownership and cleanup | Release only after a confirmed saved outcome is applied. Otherwise retain the same service and exact recovery capability; incomplete cleanup is reported explicitly. |
| Cancellation | Observation timeout and shutdown do not supply cancellation authority or prove physical completion. No new cancellation behavior is proposed. |
| External effects | The Provider is offline and counted. No Tool, child admission or external side effect occurs in this application comparison. |
| Retry policy | `retry_confirmed_pre: false` holds the exact pre-state; `true` explicitly permits only captured persistence writes. |

The ordinary domain is equivalent: both columns below use the same application source and preserve the same business contract. Fault observations intentionally differ as follows.

| Condition | Before: applied G3i | After: G3j candidate |
| --- | --- | --- |
| No injected fault | Normal success or original business error; one Provider call and ordinary release. | Same ordinary behavior and application function. |
| Original output changes after capture, then an eligible save is reconciled or retried | The stored report can retain the original text while the recovery receipt reports the changed String. | Recovery result and Store observation both use the captured text. |
| Original exception accessor becomes unavailable after capture | A saved failed execution can remain unavailable and retained because publication reads the live exception again. | The captured diagnostic supports publication and release without another diagnostic read. |
| Exact pre-state and application declines retry | Owner remains retained; no business or persistence replay is authorized. | Same explicit hold policy. |
| Incomplete preparation before captured facts exist | No supported generic replay or terminalization follows merely from retention. | Still unresolved; this change is not a generic preparation recovery API. |

## Shared setup and ordinary execution comparison

The same application definitions and observation helpers supply both ordinary execution functions. The offline Provider makes unexpected replay visible, while the mutable output and custom exception expose the distinction between application objects and captured facts.

For example, `build_report_service(failure: false)` installs a native-configured report parent with an output filter returning a caller-owned String. With `failure: true`, the same parent receives the exact custom business exception. Both normal functions below are complete and identical.

Copy the shared setup, common observation helpers, one column of the ordinary function, one column of the recovery function, the complete fixture and the driver into one Ruby file in that order. Every dependency is shown. Run each case in a fresh Ruby process with the chosen checkout in the bundle, because the fixture instruments that process. These are application adaptations using existing public APIs, not excerpts from a separate application repository.

<!-- g3j-code:shared-setup -->
```ruby
require "phronomy"
require "json"

class G3jReportError < Phronomy::Error
  attr_accessor :reject_reads
  attr_reader :reads

  def initialize
    @reads = 0
    super("The report source is unavailable", code: "report.source_unavailable")
  end

  def message
    @reads += 1
    raise IOError, "Original report diagnostic is no longer available" if reject_reads
    super
  end
end

class G3jReportWorker < Phronomy::Agent::Base
  agent_definition id: "retained-report-worker", version: 1
  model "offline-model"
end

class G3jReportParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "retained-report-parent", version: 1
  model "offline-model"
  subagent :reviewer, G3jReportWorker
end

class G3jReportAdapter < Phronomy::LLMAdapter::Base
  attr_reader :calls

  def initialize(error: nil)
    @error, @calls = error, 0
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @calls += 1
    raise "Unexpected repeated Provider work" if @calls > 1
    raise @error if @error
    Phronomy::LLMAdapter::Response.new(content: "Report source text", finish_reason: :stop)
  end
end

def build_report_service(failure: false)
  error = failure ? G3jReportError.new : nil
  adapter = G3jReportAdapter.new(error: error)
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  parent = G3jReportParent.create(agent_id: "retained-report-parent", persistence: stores.agent,
    coordination_store: stores.multi_agent)
  output = +"Report completed"
  parent.add_output_filter(->(_text) { output }) unless failure
  {adapter: adapter, stores: stores, parent: parent, output: output, error: error,
   execution_id: "retained-report-execution"}
end
```


<!-- g3j-code:common-observation -->
```ruby
def stored_report(service)
  parent = service.fetch(:parent)
  fact = service.fetch(:stores).agent.observe_execution(agent_id: parent.agent_id,
    execution_id: service.fetch(:execution_id))
  {status: fact.status, result: fact.result, raw_output: fact.raw_output, error: fact.error}
end

def report_receipt(receipt)
  execution = receipt.execution
  {outcome: receipt.outcome, application_state: receipt.application_state,
   ownership_state: receipt.ownership_state, saved_outcome: receipt.saved_outcome,
   execution: execution && {status: execution.status, result: execution.result,
                           raw_output: execution.raw_output, error: execution.error}}
end

def release_report(service)
  service.fetch(:parent).unload!
end

def start_report(service)
  parent = service.fetch(:parent)
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id,
    execution_id: service.fetch(:execution_id))
  parent.start_hosted(reservation: reservation, input: "Prepare one report")
end
```


<table>
<thead><tr><th>Before: applied G3i</th><th>After: G3j candidate</th></tr></thead>
<tbody><tr>
<td><pre><code><!-- g3j-code:normal-function:before -->def run_report(failure: false)
  service = build_report_service(failure: failure)
  original = start_report(service)
  original_error = nil
  begin
    original.wait_result(timeout: 8)
  rescue G3jReportError =&gt; error
    original_error = error
  end
  {state: :ordinary, stored: stored_report(service),
   original_business_error_preserved: failure ? original_error.equal?(service.fetch(:error)) : nil,
   provider_calls: service.fetch(:adapter).calls, released: release_report(service)}
end
</code></pre></td>
<td><pre><code><!-- g3j-code:normal-function:after -->def run_report(failure: false)
  service = build_report_service(failure: failure)
  original = start_report(service)
  original_error = nil
  begin
    original.wait_result(timeout: 8)
  rescue G3jReportError =&gt; error
    original_error = error
  end
  {state: :ordinary, stored: stored_report(service),
   original_business_error_preserved: failure ? original_error.equal?(service.fetch(:error)) : nil,
   provider_calls: service.fetch(:adapter).calls, released: release_report(service)}
end
</code></pre></td>
</tr></tbody>
</table>


## Explicit recovery comparison

Recovery policy remains visible in the application: observe the retained owner, permit a captured-write retry only from confirmed pre-state when requested, and keep unresolved responsibility alive. G3j changes the reliability of the returned facts without adding an application branch or asking the application to cache a parallel error representation.

For example, the report service reconciles a lost response and retries only when `retry_confirmed_pre` is true. A second reconciliation must return the same saved facts after release, and a second wait on the original task must return the same failure object. Both functions below make that policy explicit.

<table>
<thead><tr><th>Before: applied G3i</th><th>After: G3j candidate</th></tr></thead>
<tbody><tr>
<td><pre><code><!-- g3j-code:recovery-function:before --># The application explicitly permits a persistence-only retry from an exact
# pre-state. It never repeats the report to infer whether its save succeeded.
def run_report_with_recovery(fault:, retry_confirmed_pre: false, failure: false)
  service = build_report_service(failure: failure)
  fault.call(service)
  parent = service.fetch(:parent)
  original = start_report(service)
  original_failure = nil
  ordinary_error = nil
  begin
    original.wait_result(timeout: 8)
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    original_failure = error
  rescue G3jReportError =&gt; error
    ordinary_error = error
  end

  unless original_failure
    return {state: :ordinary, stored: stored_report(service),
            original_business_error_preserved: failure ? ordinary_error.equal?(service.fetch(:error)) : nil,
            provider_calls: service.fetch(:adapter).calls, released: release_report(service)}
  end

  recovery = original_failure.recovery
  raise "Unexpected retained owner" unless parent.pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
  first = parent.reconcile_outcome(recovery: recovery)
  if first.outcome == :confirmed_pre &amp;&amp; retry_confirmed_pre
    first = parent.retry_outcome(recovery: recovery)
  end
  # A second observation must preserve the same stored facts, including after
  # release. A closed original task must not be reopened by either observation.
  second = parent.reconcile_outcome(recovery: recovery)
  begin
    original.wait_result(timeout: 8)
    raise "Original failed observation reopened"
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    raise "Original observation changed" unless error.equal?(original_failure)
  end
  released = first.ownership_state == :released
  release_report(service) if released
  {state: released ? :recovered : :retained, stored: stored_report(service),
   observations: [report_receipt(first), report_receipt(second)],
   provider_calls: service.fetch(:adapter).calls, released: released,
   original_observation_closed: true,
   retained_service: released ? nil : service, retained_recovery: released ? nil : recovery}
end
</code></pre></td>
<td><pre><code><!-- g3j-code:recovery-function:after --># The application explicitly permits a persistence-only retry from an exact
# pre-state. It never repeats the report to infer whether its save succeeded.
def run_report_with_recovery(fault:, retry_confirmed_pre: false, failure: false)
  service = build_report_service(failure: failure)
  fault.call(service)
  parent = service.fetch(:parent)
  original = start_report(service)
  original_failure = nil
  ordinary_error = nil
  begin
    original.wait_result(timeout: 8)
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    original_failure = error
  rescue G3jReportError =&gt; error
    ordinary_error = error
  end

  unless original_failure
    return {state: :ordinary, stored: stored_report(service),
            original_business_error_preserved: failure ? ordinary_error.equal?(service.fetch(:error)) : nil,
            provider_calls: service.fetch(:adapter).calls, released: release_report(service)}
  end

  recovery = original_failure.recovery
  raise "Unexpected retained owner" unless parent.pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
  first = parent.reconcile_outcome(recovery: recovery)
  if first.outcome == :confirmed_pre &amp;&amp; retry_confirmed_pre
    first = parent.retry_outcome(recovery: recovery)
  end
  # A second observation must preserve the same stored facts, including after
  # release. A closed original task must not be reopened by either observation.
  second = parent.reconcile_outcome(recovery: recovery)
  begin
    original.wait_result(timeout: 8)
    raise "Original failed observation reopened"
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    raise "Original observation changed" unless error.equal?(original_failure)
  end
  released = first.ownership_state == :released
  release_report(service) if released
  {state: released ? :recovered : :retained, stored: stored_report(service),
   observations: [report_receipt(first), report_receipt(second)],
   provider_calls: service.fetch(:adapter).calls, released: released,
   original_observation_closed: true,
   retained_service: released ? nil : service, retained_recovery: released ? nil : recovery}
end
</code></pre></td>
</tr></tbody>
</table>


The application does not become shorter. Its benefit is that its existing recovery policy can trust the saved result without keeping a second authoritative output or reconstructing a generic diagnostic. The application still decides retry, observes new recovery results, retains unresolved owners and performs ordinary cleanup. A wrapper that automatically retries or invents a terminal failure would hide those responsibilities and is not added.

## Complete fault fixture and driver

The fixture creates only the environmental failures needed to compare publication. It leaves the real Runtime, coordinator, persistence transaction, evidence comparison and captured-write retry in place, and it measures Provider, committer and encoder execution separately.

For example, `mode: :pre` executes the transaction and raises inside its scope so the original save rolls back; `mode: :post` raises only after the real transaction returns, so the save has committed. Each mode also loses the immediate readback once. A diagnostic mutation happens immediately after complete evidence capture, before publication can consult the original error again.

<!-- g3j-code:fault-fixture -->
```ruby
# This test fixture changes caller-owned values after complete capture and
# injects a transaction response loss. It does not replace persistence logic.
module G3jReportFault
  class << self
    attr_accessor :current

    def selected?(command)
      current && command.execution_id == current.fetch(:execution_id)
    end

    def context
      Thread.current[:g3j_report_outcome]
    end

    def after_capture(evidence)
      fault = current
      return unless fault && evidence.execution_id == fault.fetch(:execution_id)
      fault[:captures] += 1
      raise "Outcome captured twice" if fault[:captures] > 1
      fault[:captured_result] = evidence.outcome.result&.slice(:output, :raw_output)
      fault[:captured_error] = evidence.outcome.error_diagnostic
      if fault[:mutation] == :output
        fault.fetch(:service).fetch(:output).replace("Changed after capture")
      elsif fault[:mutation] == :diagnostic
        error = fault.fetch(:service).fetch(:error)
        fault[:diagnostic_reads_at_capture] = error.reads
        error.reject_reads = true
      end
    end

    def report
      return {enabled: false} unless current
      error = current.fetch(:service)[:error]
      {enabled: true, mode: current[:mode], mutation: current[:mutation],
       captures: current[:captures], failures: current[:failures],
       committer_calls: current[:committer_calls], encoder_calls: current[:encoder_calls],
       captured_result: current[:captured_result], captured_error: current[:captured_error],
       diagnostic_reads_after_capture: error && current[:diagnostic_reads_at_capture] &&
         error.reads - current[:diagnostic_reads_at_capture]}
    end
  end
end

module G3jCommitScope
  def commit_outcome(command, **options)
    previous = Thread.current[:g3j_report_outcome]
    selected = G3jReportFault.selected?(command)
    Thread.current[:g3j_report_outcome] = selected ? G3jReportFault.current : nil
    G3jReportFault.current[:committer_calls] += 1 if selected
    super
  ensure
    Thread.current[:g3j_report_outcome] = previous
  end
end

module G3jCapturedEvidence
  def capture_evidence(evidence)
    super
    G3jReportFault.after_capture(evidence)
  end
end

module G3jEncodingCount
  def encode(*args, **options)
    G3jReportFault.context[:encoder_calls] += 1 if G3jReportFault.context
    super
  end
end

module G3jTransactionResponse
  def atomic(*args, &transaction)
    fault = G3jReportFault.context
    return super unless fault && fault[:mode] != :none
    if fault[:readback_loss]
      fault[:readback_loss] = false
      raise IOError, "Immediate report save readback unavailable"
    end
    return super unless fault[:armed]
    fault[:armed] = false
    fault[:failures] += 1
    if fault[:mode] == :pre
      super(*args) do |scope|
        transaction.call(scope)
        fault[:readback_loss] = true
        raise IOError, "Report save rolled back and response lost"
      end
    else
      super(*args, &transaction)
      fault[:readback_loss] = true
      raise IOError, "Report save committed and response lost"
    end
  end
end

Phronomy::Agent::ExecutionOutcomeCommitter.prepend(G3jCommitScope)
Phronomy::Agent::OutcomeRecoveryOperation.prepend(G3jCapturedEvidence)
Phronomy::Agent::RuntimeRecordEncoder.singleton_class.prepend(G3jEncodingCount)

def report_fault(mutation:, mode:)
  raise ArgumentError, "Unknown mutation" unless %i[none output diagnostic].include?(mutation)
  raise ArgumentError, "Unknown response loss" unless %i[none pre post].include?(mode)
  lambda do |service|
    service.fetch(:stores).agent.coordinator.singleton_class.prepend(G3jTransactionResponse)
    G3jReportFault.current = {service: service, execution_id: service.fetch(:execution_id),
      mutation: mutation, mode: mode, armed: true, readback_loss: false,
      captures: 0, failures: 0, committer_calls: 0, encoder_calls: 0}
  end
end
```


<!-- g3j-code:shared-driver -->
```ruby
# Pending results retain the live owner and exact recovery capability. A real
# service must keep these values until resolution. This process only reports
# the retained state and the incomplete cleanup; it provides no restart path.
def run_report_example(normal: false, failure: false, mutation: :none, mode: :none,
  retry_confirmed_pre: false)
  begin
    report = if normal
      run_report(failure: failure)
    else
      run_report_with_recovery(fault: report_fault(mutation: mutation, mode: mode),
        retry_confirmed_pre: retry_confirmed_pre, failure: failure)
    end
    report = report.reject { |key, _value| %i[retained_service retained_recovery].include?(key) }
  ensure
    Phronomy::Runtime.instance.shutdown(timeout: 0.03, cancel_grace: 0.2)
    begin
      Phronomy.reset_runtime!
      cleanup_incomplete = false
    rescue Phronomy::RuntimeShutdownError
      cleanup_incomplete = true
    end
  end
  report.merge(cleanup_incomplete: cleanup_incomplete, fixture: G3jReportFault.report)
end

if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(run_report_example(normal: ENV["G3J_NORMAL"] == "true",
    failure: ENV["G3J_FAILURE"] == "true", mutation: ENV.fetch("G3J_MUTATION", "none").to_sym,
    mode: ENV.fetch("G3J_MODE", "none").to_sym,
    retry_confirmed_pre: ENV["G3J_RETRY_CAPTURED_OUTCOME"] == "true"))
end
```


The driver reports retained ownership and incomplete cleanup rather than treating process exit as successful resolution. Its bounded shutdown is test cleanup, not a supported recovery across stopped Runtime or process restart. A long-running application must keep the returned service and recovery capability alive while the result is retained.

Example invocations select one case per process:

```sh
G3J_NORMAL=true bundle exec ruby retained_report_application.rb
G3J_NORMAL=true G3J_FAILURE=true bundle exec ruby retained_report_application.rb
G3J_MUTATION=output G3J_MODE=post bundle exec ruby retained_report_application.rb
G3J_MUTATION=output G3J_MODE=pre G3J_RETRY_CAPTURED_OUTCOME=true bundle exec ruby retained_report_application.rb
G3J_FAILURE=true G3J_MUTATION=diagnostic G3J_MODE=post bundle exec ruby retained_report_application.rb
G3J_FAILURE=true G3J_MUTATION=diagnostic G3J_MODE=pre bundle exec ruby retained_report_application.rb
```

## Public contract and symmetry decisions

The shared Agent owner publishes the same captured representation for standalone terminal recovery and native terminal-outcome recovery. Comparable operations retain their own domain meanings: recovery observation does not become an approval decision, a business retry or a new durable owner.

For example, native `reconcile_outcome` and standalone `reconcile_terminal` both need the saved failure to remain readable when its original exception is no longer available. An approval wait still needs its own subsequent decision, and a positively refused worker submission still needs the separate submission-retry operation.

| Peer operation or value | Naming, values and lifecycle | Decision |
| --- | --- | --- |
| `reconcile_outcome` / `reconcile_outcome_async` | Same required exact `recovery:`; synchronous receipt or fresh `TaskResult`; read-only persistence observation. | Adopt captured publication through the existing owner. No retry flag or new default. |
| `retry_outcome` / `retry_outcome_async` | Same exact recovery capability and result family; explicit permission for eligible captured writes. | Preserve authority, physical-settlement and exact pre-state checks. |
| Standalone terminal recovery | Existing terminal-only operation family shares the recovery owner implementation. | Adopt the same captured terminal observation, rather than a separate diagnostic cache. |
| `Store#observe_execution` | Result format, raw output and full diagnostic describe saved execution facts. | Align recovery representation with the same captured content. Independently changing cancellation request facts retain their existing contract. |
| Ordinary invoke or stream delivery | Original result/error delivery follows its existing execution path. | Preserve original business exception identity and stream semantics; this comparison exercises hosted invocation, not Provider streaming. |
| Approval recovery and native waits | Decision and continuation semantics differ from terminal results. | Keep existing kind and lifetime; do not add terminal facts to a wait. |
| First-submission retry | Positive non-admission evidence is required. | Do not treat a diagnostic-publication failure as worker refusal. |
| New generic preparation retry or termination | No complete replay or disposition authority follows from mere retention. | Defer; not required to repair publication after complete capture. |

Synchronous recovery continues to reject EventLoop reentrancy. Observer timeout or cancellation closes an observation according to its existing contract; it does not end a backend transaction, authorize overlapping work or transfer the live owner. No public migration is required, but application tests that relied on a mutated recovery value must adopt the saved-value contract.

## Acceptance, model coverage and remaining limits

Acceptance separates persistence truth, local application, observation publication and physical ownership. Exact readback alone cannot prove that an application receives the right facts, so the change requires direct comparison of recovery observations with stored representations and checks that original business work is not repeated.

For example, a pre-state retry must preserve captured text after the application mutates its String, while a post-state reconciliation must publish a captured failure without re-reading its original exception. In both cases, the original failed task stays failed and the Provider and encoder counters stay at one.

| Recorded validation | Result | Interpretation |
| --- | --- | --- |
| Isolated G3i custom-diagnostic characterization | One example, zero failures; all 407 library source files match the exact baseline Git content. | Reproduces the defect: a durable failed result remains unavailable and retained when publication reads the original diagnostic again. |
| Same application matrix on baseline and candidate | Nine baseline cases and nine candidate cases match their declared expectations. | Ordinary success/failure reports are identical. Candidate recovery facts match stored output/diagnostics, with zero diagnostic reads after capture; explicit pre-state holds remain retained. |
| Source reconstructed from this document | All eight blocks match the executed source; complete before/after Ruby syntax passes; 18 direct runs match the matrix reports and selected source hashes. | Repeats the same nine cases on two versions to verify the published source, rather than adding 18 independent scenarios. |
| Existing finite model family | All 153 configurations match their declared outcomes: 73 positive properties, 55 deliberate mutations, 15 witnesses and ten missing-premise cases. | Expected negative cases demonstrate the need for a rule or environmental premise; they are not unfixed violations in the correct protocol. |

The acceptance scope includes mutable plain and structured results, structured raw output, full output-contract diagnostic fields, unavailable custom business diagnostics, standalone and native terminal owners, delayed or retried publication, exact pre/post cases, ordinary exception identity and explicit retry holds. Missing captured content must remain a precise preparation failure. The application fixture above covers its declared plain-result and business-error scenarios; independent implementation tests carry structured output, actual child obligations and other lifecycle paths. A green fixture is not a claim that every external service or backend has been audited.

The existing [native parent outcome recovery model](../../spec/models/native_parent_outcome_recovery/README.md) is extended rather than replaced. The publication abstraction distinguishes the captured fact, mutable live source and published observation. Fourteen new configurations add four safety checks, three conditional progress checks, four safety mutations, one progress mutation and two reachability witnesses; the preceding 139 configurations keep their scenarios and selected properties. `ExactPublishedPayload` requires the published fact to equal the confirmed captured value, and `NoPublicationReconversion` excludes another original diagnostic conversion. Diagnostic unavailability must not block otherwise eligible publication in pre-state, post-state or deferred-proof cases. Existing physical settlement, exact owner, retained responsibility and original-observer invariants remain required.

The new publication cases bound one captured terminal result, one later source change, two payload identities and at most two forbidden conversion attempts in the deliberate mutant. The inherited limits include one representative child, three management attempts and two observers; the 14 new cases select no child-authority drift. Raw-output mutation is an overapproximation because the concrete response content is copied and frozen. Payload-token equality is not a refinement proof of JSON decoding, complete `OutputError` fields or arbitrary Ruby conversion. The five existing entity/preparation diagrams keep their topology, and the old 139 configurations did not establish the absence of the newly represented publication defects.

A failure before complete evidence exists remains residual group 1. Existing factual resolution is limited to precise durable LLM or Tool subjects; ordinary failure encoding can itself repeat the failing conversion. Neither cancellation intent nor retaining a live owner proves that unresolved child obligations or external effects have been discharged. A future non-replaying termination requires its own disposition, audit representation and positive authority. G3j does not close that work, stopped-Runtime recovery or production-backend acceptance.
