# Finish retained outcome materialization without repeating business preparation

Agent owns accepted execution results and the observations returned to callers. Persistence owns committed facts, and MultiAgent owns native child relationships. A completed encoding must remain available when a later immutable-content read fails, so recovery can finish the known presentation work without asking the Provider, Tool or application conversion to run again.

For example, a report parent calls a Tool once, receives its final answer, and encodes its result and audit records. Reading an earlier transcript message then fails. The new private checkpoint retains those encoded facts and the fixed inputs for transcript reconstruction. A later explicit recovery can finish the read and save the same report.

This document compares applied G3j `9402709cd0ab4275825e550f3d6112198e5febe6` with the G3k candidate. Contract concept v55 and foundation v48 define the current ownership boundaries. [Native preparation](native-outcome-preparation.md), [native outcome recovery](native-parent-outcome-recovery.md) and [captured publication](retained-outcome-publication.md) remain the preceding contracts. The new stage adds no public API, participant SPI, automatic retry policy or general preparation-replay permission.

## Encoded intent and result presentation are different stages

The native outcome worker prepares domain facts once, then reconstructs the ordinary transcript from captured and historical content. Encoded save intent can be complete before ordinary presentation is complete. A separate retained stage makes that distinction explicit without weakening complete persistence evidence.

For the report, final answer bytes, record identities, execution/root records and native retention facts have already been chosen before an old transcript message is read. Rereading that message by immutable reference is permitted. Calling the original output's conversion again, revalidating its schema or selecting new child acknowledgements is not.

| Responsibility | Captured or repeated work | Rule |
| --- | --- | --- |
| Business execution | Provider calls, Tool effects, output filtering and semantic validation | Do not repeat during outcome recovery. |
| Native planning | Planned child/approval/cancellation/retention facts | Capture once; do not rerun the planning policy to finish presentation. |
| Encoding | Output, diagnostics, audit content, record IDs and times | Reuse captured bytes and values. |
| Ordinary transcript presentation | Fixed root/record inputs, captured new content and immutable historical content | May finish on a worker after the original worker physically settles. |
| Complete persistence input | Full semantic outcome plus exact before/after facts and writes | Keep its strong contract. Construct it once and cache success or failure; copying an application-owned value is not generally repeatable. |
| Save confirmation and write retry | Exact readback, original Store/owner and current native authority | Reconcile reads; a caller-selected retry writes only an eligible captured plan. |
| Publication and release | Complete local result and G3j captured observation | Apply only on the original EventLoop under existing ownership rules. |

The private `OutcomePreparation` holds the intermediate data separately from `TerminalPersistenceEvidence::CapturedInput`. `ExecutionChange` retains it before hydration, and `OutcomeRecoveryOperation` completes it through the existing worker lane after physical settlement. Its read adapter uses retained new content and fresh historical content access, checking reference digests; it does not retain a transaction scope or call the native planning policy again.

Only the completed-result transcript path gains the new retained stage. Existing failure, approval and coordination preparation does not gain permission to repeat diagnostics or request conversion. After hydration succeeds, complete-input construction is attempted once: a String subclass can execute application code during copying, so constructor failure remains retained without reentry. If the original read failed before that step, recovery may execute the constructor for the first time. The guarantee is no repeated constructor execution, not an assertion that every recovery-worker operation is application-code-free. An already completed input still supports the existing data-only proof reconstruction.

The initial successful path still materializes its ordinary result before physical writes. Recovery does not retain a closed transaction reader or an arbitrary application continuation. Historical reads use the supplied original Store; new content comes from the retained encoded writes. A permanently unavailable or corrupt immutable reference remains an unresolved read failure.

## Application scenario and behavioral contract

The application owns retry permission, observation and retention of unresolved responsibility. The framework owns the continuation of its explicitly classified immutable-content work and the fidelity of the result. The application must not reconstruct a parallel report or guess whether another Provider/Tool execution is safe.

For example, the report application uses a real Runtime and in-memory Persistence with an offline counted Provider and one counted Tool. A native parent declares a reviewer but does not dispatch it in this bounded example. The fixture makes a historical content read fail during final transcript materialization, after encoding is complete.

| Aspect | Shared contract |
| --- | --- |
| Input/output | Same report request, final answer, Tool result and existing result shapes. |
| Ordering/effects | Two Provider calls and one Tool effect; no semantic replay during recovery. |
| Errors | Original failed observation stays closed; later recovery produces a fresh observation. |
| Persistence | Actual transactions, readback and captured-write retry. Read faults are injected at the real repository boundary. |
| Ownership | Same original retained owner; release only after confirmed application and physical settlement. |
| Cancellation | Observer cancellation does not authorize overlapping work, cancel shared recovery or discard custody. |
| Retry policy | Only explicit permission after confirmed pre-state allows captured writes. |
| Cleanup | Successful cleanup and retained unresolved responsibility are reported separately; test process exit is not a recovery mechanism. |
| Public result shape | Ordinary invocation includes messages; exact resume returns its existing stored-result shape; recovery returns its existing execution observation. |

Ordinary behavior is equivalent. The intended failure behavior changes as follows.

| Condition | Before: applied G3j | After: G3k candidate |
| --- | --- | --- |
| No fault | Ordinary complete report and cleanup. | Same output, transcript, counts and cleanup. |
| Transient historical read failure after encoding | Original owner remains unavailable with no complete proposal to recover. | Retained stage can finish hydration; reconcile can report confirmed pre-state without writes. |
| Explicit retry after successful hydration | No permitted continuation for the lost intermediate stage. | Existing exact-write retry can commit the retained report without business or encoding replay. |
| Caller declines retry | Retained unresolved responsibility. | Hydration/readback may establish confirmed pre-state, but the owner stays retained and no writes occur. |
| Content remains unavailable | Retained unresolved responsibility. | Same retained responsibility; no fabricated transcript or terminal result. |
| Opaque conversion fails before the new checkpoint | No generic replay or forced terminalization is justified. | Still outside this repair and remains residual group 1. |

## Shared setup and ordinary execution

Both application versions use the same definitions and ordinary execution policy. The counted Provider and Tool expose accidental repeated work, while the complete result comparison protects ordinary caller-visible behavior.

For the report, the normal path waits for the final result, observes its stored counterpart and performs explicit cleanup. The two ordinary functions below are identical. The fixture is a test adaptation using existing public APIs, not a separate production application repository.

Copy shared setup, shared observation helpers, one normal-function column, one recovery-function column, the fixture and driver into one Ruby file in that order. All dependencies and policy are shown. Run one case per fresh process because the fixture instruments that process.

<!-- g3k-code:shared-setup -->
```ruby
require "phronomy"
require "json"

class G3kReportError < Phronomy::Error
  def initialize
    super("The report source is unavailable", code: "report.source_unavailable")
  end
end

class G3kReportOutput
  def initialize(counts)
    @counts = counts
  end

  def to_s
    @counts[:output_conversion] += 1
    "Report completed"
  end
end

class G3kReportTool < Phronomy::Tool::Base
  tool_name "read_report_source"
  description "Read the report source once"
  param :topic, type: :string, desc: "Report topic"
  class << self
    attr_accessor :counts
  end

  def execute(topic:)
    self.class.counts[:tool] += 1
    raise "Unexpected repeated Tool work" if self.class.counts[:tool] > 1
    "Source facts for #{topic}"
  end
end

class G3kReportWorker < Phronomy::Agent::Base
  agent_definition id: "materialized-report-worker", version: 1
  model "offline-model"
end

class G3kReportParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "materialized-report-parent", version: 1
  model "offline-model"
  tools G3kReportTool => nil
  subagent :reviewer, G3kReportWorker
end

class G3kReportAdapter < Phronomy::LLMAdapter::Base
  def initialize(counts, error: nil)
    @counts, @error = counts, error
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @counts[:provider] += 1
    case @counts[:provider]
    when 1
      Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "report-source-call", name: "read_report_source", arguments: {topic: "retained outcomes"})
      ])
    when 2
      raise @error if @error
      Phronomy::LLMAdapter::Response.new(content: "Report source text", finish_reason: :stop)
    else
      raise "Unexpected repeated Provider work"
    end
  end
end

def build_report_service(failure: false)
  counts = Hash.new(0)
  error = failure ? G3kReportError.new : nil
  G3kReportTool.counts = counts
  adapter = G3kReportAdapter.new(counts, error: error)
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  parent = G3kReportParent.create(agent_id: "materialized-report-parent", persistence: stores.agent,
    coordination_store: stores.multi_agent)
  output = G3kReportOutput.new(counts)
  parent.add_output_filter(->(_text) { output }) unless failure
  {counts: counts, stores: stores, parent: parent, output: output, error: error}
end
```


<!-- g3k-code:common-observation -->
```ruby
def report_messages(messages)
  messages.map do |message|
    message.to_h.reject { |key, _value| key == "metadata" }
  end
end

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
  service.fetch(:parent).invoke_async("Prepare one report")
end
```


<table>
<thead><tr><th>Before: applied G3j</th><th>After: G3k candidate</th></tr></thead>
<tbody><tr>
<td><pre><code><!-- g3k-code:normal-function:before -->def run_report(failure: false)
  service = build_report_service(failure: failure)
  report_fault(read_failure: :none, save_loss: :none).call(service)
  original = start_report(service)
  result = nil
  original_error = nil
  begin
    result = original.wait_result(timeout: 8)
  rescue G3kReportError =&gt; error
    original_error = error
  end
  transcript = service.fetch(:parent).transcript_messages
  messages_match = result &amp;&amp; result.fetch(:messages).map(&amp;:to_h) == transcript.map(&amp;:to_h)
  {state: :ordinary, stored: stored_report(service),
   original_business_error_preserved: failure ? original_error.equal?(service.fetch(:error)) : nil,
   original_output_preserved: result &amp;&amp; result.fetch(:output).equal?(service.fetch(:output)),
   complete_result_messages_match_transcript: messages_match,
   transcript: report_messages(transcript), counts: service.fetch(:counts),
   released: release_report(service)}
end
</code></pre></td>
<td><pre><code><!-- g3k-code:normal-function:after -->def run_report(failure: false)
  service = build_report_service(failure: failure)
  report_fault(read_failure: :none, save_loss: :none).call(service)
  original = start_report(service)
  result = nil
  original_error = nil
  begin
    result = original.wait_result(timeout: 8)
  rescue G3kReportError =&gt; error
    original_error = error
  end
  transcript = service.fetch(:parent).transcript_messages
  messages_match = result &amp;&amp; result.fetch(:messages).map(&amp;:to_h) == transcript.map(&amp;:to_h)
  {state: :ordinary, stored: stored_report(service),
   original_business_error_preserved: failure ? original_error.equal?(service.fetch(:error)) : nil,
   original_output_preserved: result &amp;&amp; result.fetch(:output).equal?(service.fetch(:output)),
   complete_result_messages_match_transcript: messages_match,
   transcript: report_messages(transcript), counts: service.fetch(:counts),
   released: release_report(service)}
end
</code></pre></td>
</tr></tbody>
</table>


## Explicit recovery and retained responsibility

The recovery function observes the exact retained owner, permits writes only under the application's declared policy, and keeps the failed original observer separate from new observations. The new implementation makes the existing function useful after the bounded read fault without adding an application-specific recovery branch.

For the report, reconciliation can finish transcript hydration and return confirmed pre-state. If retry is permitted, the same captured report is saved. If retry is declined or the read remains unavailable, the function reports the retained owner and incomplete cleanup instead of declaring the job finished.

<table>
<thead><tr><th>Before: applied G3j</th><th>After: G3k candidate</th></tr></thead>
<tbody><tr>
<td><pre><code><!-- g3k-code:recovery-function:before --># Retrying a confirmed pre-state is an explicit persistence policy. It does not
# authorize repeating the report, output conversion or native preparation.
def run_report_with_recovery(fault:, retry_confirmed_pre: false, late_observer: false)
  service = build_report_service
  fault.call(service)
  parent = service.fetch(:parent)
  original = start_report(service)
  original_failure = nil
  begin
    original.wait_result(timeout: 8)
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    original_failure = error
  end
  raise "Expected an ambiguous report observation" unless original_failure
  recovery = original_failure.recovery
  raise "Unexpected retained owner" unless parent.pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
  counts_after_failure = service.fetch(:counts).dup
  resumed = late_observer ? parent.resume_async(service.fetch(:execution_id)) : nil
  reconciled = parent.reconcile_outcome(recovery: recovery)
  after_reconcile = stored_report(service)
  first = reconciled
  if first.outcome == :confirmed_pre &amp;&amp; retry_confirmed_pre
    first = parent.retry_outcome(recovery: recovery)
  end
  second = parent.reconcile_outcome(recovery: recovery)
  begin
    original.wait_result(timeout: 8)
    raise "Original failed observation reopened"
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    raise "Original observation changed" unless error.equal?(original_failure)
  end
  released = first.ownership_state == :released
  resumed_result = resumed.wait_result(timeout: 8) if resumed &amp;&amp; released
  transcript = released ? parent.transcript_messages : nil
  release_report(service) if released
  {state: released ? :recovered : :retained, stored: stored_report(service),
   reconciliation: report_receipt(reconciled), after_reconciliation: after_reconcile,
   observations: [report_receipt(first), report_receipt(second)],
   late_observer: resumed ? {requested: true, completed: resumed.done?,
     result: resumed_result &amp;&amp; resumed_result.slice(:status, :result, :output)} : {requested: false},
   transcript: transcript &amp;&amp; report_messages(transcript), counts: service.fetch(:counts),
   counts_after_failure: counts_after_failure, released: released,
   original_observation_closed: true,
   retained_service: released ? nil : service, retained_recovery: released ? nil : recovery,
   retained_observer: released ? nil : resumed}
end
</code></pre></td>
<td><pre><code><!-- g3k-code:recovery-function:after --># Retrying a confirmed pre-state is an explicit persistence policy. It does not
# authorize repeating the report, output conversion or native preparation.
def run_report_with_recovery(fault:, retry_confirmed_pre: false, late_observer: false)
  service = build_report_service
  fault.call(service)
  parent = service.fetch(:parent)
  original = start_report(service)
  original_failure = nil
  begin
    original.wait_result(timeout: 8)
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    original_failure = error
  end
  raise "Expected an ambiguous report observation" unless original_failure
  recovery = original_failure.recovery
  raise "Unexpected retained owner" unless parent.pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
  counts_after_failure = service.fetch(:counts).dup
  resumed = late_observer ? parent.resume_async(service.fetch(:execution_id)) : nil
  reconciled = parent.reconcile_outcome(recovery: recovery)
  after_reconcile = stored_report(service)
  first = reconciled
  if first.outcome == :confirmed_pre &amp;&amp; retry_confirmed_pre
    first = parent.retry_outcome(recovery: recovery)
  end
  second = parent.reconcile_outcome(recovery: recovery)
  begin
    original.wait_result(timeout: 8)
    raise "Original failed observation reopened"
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    raise "Original observation changed" unless error.equal?(original_failure)
  end
  released = first.ownership_state == :released
  resumed_result = resumed.wait_result(timeout: 8) if resumed &amp;&amp; released
  transcript = released ? parent.transcript_messages : nil
  release_report(service) if released
  {state: released ? :recovered : :retained, stored: stored_report(service),
   reconciliation: report_receipt(reconciled), after_reconciliation: after_reconcile,
   observations: [report_receipt(first), report_receipt(second)],
   late_observer: resumed ? {requested: true, completed: resumed.done?,
     result: resumed_result &amp;&amp; resumed_result.slice(:status, :result, :output)} : {requested: false},
   transcript: transcript &amp;&amp; report_messages(transcript), counts: service.fetch(:counts),
   counts_after_failure: counts_after_failure, released: released,
   original_observation_closed: true,
   retained_service: released ? nil : service, retained_recovery: released ? nil : recovery,
   retained_observer: released ? nil : resumed}
end
</code></pre></td>
</tr></tbody>
</table>


The application does not become shorter. It benefits because the framework retains its own intermediate evidence and finishes its own read-only work. The application still owns retry, unresolved-owner lifetime and cleanup; it does not acquire a generic right to rerun semantic preparation.

## Complete fault fixture and driver

The fixture changes only the environment at the real immutable-content and transaction boundaries. It leaves the Runtime, native policy, encoding, exact comparison and writes intact. Counts separate repeated presentation reads from forbidden repeated business work.

For example, a transient historical read failure can recover while a permanent read failure stays retained. A later committed-response loss remains a persistence-reconciliation case after the stage has completed. A late exact observer must retain its existing Store-result shape; it does not gain an ordinary transcript field.

<!-- g3k-code:fault-fixture -->
```ruby
# The fixture counts actual terminal preparation and fails an actual immutable
# content read or a real transaction response. It never supplies an outcome.
module G3kReportFault
  class << self
    attr_accessor :current

    def report
      return {enabled: false} unless current
      current.slice(:read_failure, :save_loss, :read_failures, :save_failures,
        :committer_calls, :encoder_calls, :materialization_calls)
    end
  end
end

module G3kCommitScope
  def commit_outcome(command, **options)
    fault = G3kReportFault.current
    selected = fault && command.root.agent_id == fault.fetch(:service).fetch(:parent).agent_id
    previous = Thread.current[:g3k_report_outcome]
    Thread.current[:g3k_report_outcome] = selected ? fault : nil
    if selected
      fault.fetch(:service)[:execution_id] = command.execution_id
      fault[:committer_calls] += 1
    end
    super
  ensure
    Thread.current[:g3k_report_outcome] = previous
  end
end

module G3kEncodingCount
  def encode(*args, **options)
    fault = Thread.current[:g3k_report_outcome]
    fault[:encoder_calls] += 1 if fault
    super
  end
end

module G3kTranscriptScope
  def materialize_transcript(root:, records:)
    fault = G3kReportFault.current
    selected = fault && root.agent_id == fault.fetch(:service).fetch(:parent).agent_id
    previous = Thread.current[:g3k_report_transcript]
    Thread.current[:g3k_report_transcript] = selected ? fault : nil
    fault[:materialization_calls] += 1 if selected
    super
  ensure
    Thread.current[:g3k_report_transcript] = previous
  end
end

module G3kTranscriptRead
  def fetch(reference)
    fault = Thread.current[:g3k_report_transcript]
    should_fail = fault && fault.fetch(:service).fetch(:counts)[:output_conversion] > 0 &&
      (fault[:read_failure] == :permanent || (fault[:read_failure] == :once && fault[:read_failures].zero?))
    if should_fail
      fault[:read_failures] += 1
      raise IOError, "Immutable report transcript content is unavailable"
    end
    super
  end
end

module G3kSaveResponse
  def atomic(*args, &transaction)
    fault = Thread.current[:g3k_report_outcome]
    return super unless fault && fault[:save_loss] != :none
    if fault[:readback_loss]
      fault[:readback_loss] = false
      raise IOError, "Immediate report save readback unavailable"
    end
    return super unless fault[:save_armed]
    fault[:save_armed] = false
    if fault[:save_loss] == :pre
      super(*args) do |scope|
        transaction.call(scope)
        fault[:save_failures] += 1
        fault[:readback_loss] = true
        raise IOError, "Report save rolled back and response lost"
      end
    else
      super(*args, &transaction)
      fault[:save_failures] += 1
      fault[:readback_loss] = true
      raise IOError, "Report save committed and response lost"
    end
  end
end

Phronomy::Agent::ExecutionOutcomeCommitter.prepend(G3kCommitScope)
Phronomy::Agent::RuntimeRecordEncoder.singleton_class.prepend(G3kEncodingCount)
Phronomy::Agent::RuntimeInput.prepend(G3kTranscriptScope)
Phronomy::Persistence::ContentRepository.prepend(G3kTranscriptRead)

def report_fault(read_failure:, save_loss:)
  raise ArgumentError, "Unknown read failure" unless %i[none once permanent].include?(read_failure)
  raise ArgumentError, "Unknown response loss" unless %i[none pre post].include?(save_loss)
  lambda do |service|
    service.fetch(:stores).agent.coordinator.singleton_class.prepend(G3kSaveResponse)
    G3kReportFault.current = {service: service, read_failure: read_failure, save_loss: save_loss,
      save_armed: true, readback_loss: false, read_failures: 0, save_failures: 0,
      committer_calls: 0, encoder_calls: 0, materialization_calls: 0}
  end
end
```


<!-- g3k-code:shared-driver -->
```ruby
# An unresolved result retains the live owner and exact capability. A service
# must keep these values; process exit is not a handoff or recovery mechanism.
def run_report_example(normal: false, failure: false, read_failure: :none,
  save_loss: :none, retry_confirmed_pre: false, late_observer: false)
  begin
    report = if normal
      run_report(failure: failure)
    else
      run_report_with_recovery(fault: report_fault(read_failure: read_failure, save_loss: save_loss),
        retry_confirmed_pre: retry_confirmed_pre, late_observer: late_observer)
    end
    report = report.reject { |key, _value| %i[retained_service retained_recovery retained_observer].include?(key) }
  ensure
    fixture = G3kReportFault.report
    Phronomy::Runtime.instance.shutdown(timeout: 0.03, cancel_grace: 0.2)
    begin
      Phronomy.reset_runtime!
      cleanup_incomplete = false
    rescue Phronomy::RuntimeShutdownError
      cleanup_incomplete = true
    end
  end
  report.merge(cleanup_incomplete: cleanup_incomplete, fixture: fixture)
end

if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(run_report_example(normal: ENV["G3K_NORMAL"] == "true",
    failure: ENV["G3K_FAILURE"] == "true", read_failure: ENV.fetch("G3K_READ_FAILURE", "none").to_sym,
    save_loss: ENV.fetch("G3K_SAVE_LOSS", "none").to_sym,
    retry_confirmed_pre: ENV["G3K_RETRY_CAPTURED_OUTCOME"] == "true",
    late_observer: ENV["G3K_LATE_OBSERVER"] == "true"))
end
```


The driver's bounded shutdown is fixture cleanup. A service that elects to retain responsibility must keep the original owner and recovery capability alive. The example does not establish failed-Runtime administration, process-loss recovery, real external-service acceptance or production SQL guarantees.

## Public symmetry and preserved distinctions

The same exact owner and public recovery family manage the additional private stage. Comparable operations share their existing sync/async and custody rules, while business submission, approval decisions and factual resolution retain different authority.

For example, `reconcile_outcome` may read and finish the permitted suffix but cannot write a report merely because a read succeeded. `retry_outcome` expresses explicit write permission. `retry_outcome_submission` still requires positive original non-admission; a failed transcript read proves the opposite.

| Peer | Decision and rationale |
| --- | --- |
| Outcome reconcile, sync/async | Same required `recovery:` and result family. May finish only the recorded immutable-content suffix before readback. |
| Outcome retry, sync/async | Same explicit write authority; exact pre-state/current native authority remain required. |
| Original submission retry | Preserve positive refusal requirement. Never treat admitted incomplete materialization as non-admission. |
| Ordinary invoke/stream | Preserve existing semantic result, error and listener contracts. The bounded example does not exercise every streaming behavior. |
| Exact reserved execution observation | Preserve `Store#result`-based shape. The waiter ignores the internal result and rereads durable facts. |
| Recovery `ExecutionObservation` | Keep G3j captured result/raw-output/diagnostic representation, independent of later mutable application objects. |
| Approval/coordination waits | Keep existing kind, authority and lifetime; a wait is not final completion or permission to run a protected Tool. |
| Standalone/Handoff/custom preparation | No general new guarantee follows from the native checkpoint. Their unsupported paths remain separately scoped. |
| Generic preparation retry or forced failure | Not added. Arbitrary conversion may have unknown effects and cannot inherit immutable-read repeatability. |

A pre-read of old transcript content cannot eliminate this stage: newly encoded messages and final projection exist only after encoding. Writing before presentation would change initial save semantics, and omitting messages would weaken ordinary success. A distinct private capsule is the bounded choice.

## Acceptance and limits of the model

Acceptance must link the exact candidate source to actual behavior and preserve the difference between ordinary results, exact observations and recovery receipts. The finite model checks the protocol under explicit assumptions; concrete Ruby tests check the content and conversion boundaries.

For the report, the accepted candidate must finish a transient read failure without increasing Provider/Tool/encoder/conversion counts, preserve complete ordinary messages, keep exact-observer shapes and publish a result equal to stored bytes. Permanent unavailability and refused explicit writes must remain visible retained outcomes.

| Recorded validation | Result | Scope |
| --- | --- | --- |
| Same complete application on baseline and candidate | Ten baseline cases and ten candidate cases match their version-specific expectations. | Ordinary success/failure reports are identical; selected read-recovery cases preserve Provider/Tool/conversion counts and explicit hold policies. |
| Loaded source provenance | All 407 baseline library files match the applied Git blobs; all 408 candidate files match the candidate source. | The five production differences are the four modified boundaries and the new private preparation class. |
| Published source correspondence | All eight complete units match the frozen source; both assembled files pass Ruby syntax and all 20 direct document executions match the application reports and loaded source hashes. | These are the same ten cases on two versions, rerun to verify the published source, not 20 additional independent scenarios. |

Runtime acceptance and complete regression totals are recorded with the exact delivery commit. The bounded application deliberately does not dispatch its declared child or contact external services. Independent Runtime cases exercise lifecycle/authority boundaries that this small example does not cover. Passing a retained-policy case means the expected responsibility remained retained, not that cleanup completed.

The existing [native outcome model family](../../spec/models/native_parent_outcome_recovery/README.md) is extended with a retained encoded stage and read-only hydration. The complete prior family remains the historical baseline. No new state diagram is needed merely to refine an existing preparation transition. Exact bounded configurations, expected negative outcomes and execution hashes accompany the change. Immutable-read eventual success, physical completion, original ownership and appropriate storage/authority assumptions remain premises; no unconditional progress or full Ruby refinement theorem is claimed.

## Remaining preparation work

The new checkpoint closes only the post-encoding presentation class. Earlier reads, partial encoding, arbitrary conversion and unsupported participant paths still need an explicit recovery or disposition contract. Keeping an owner alive is a safety property, not completion of the lifecycle.

For example, a Tool's external effect may already have occurred when its result object's `to_h` raises. No unchanged Store or cancellation request proves that converting it again is safe. Writing a generic parent failure also does not dispose of an active child's responsibility.

| Remaining class | Required decision |
| --- | --- |
| Read-only prefix before the capsule | Fixed inputs and repeatability boundary, with native-policy selection and exact-state checks specified. |
| Failed arbitrary conversion/diagnostic or complete-input copying | Explicit retained-unresolved, exact-subject replacement or intentional-abandonment semantics; no silent retry. |
| Partially completed encoding | Reuse completed facts and generated identities without repeating application conversions. |
| Intentional terminal disposition | State what it means about accepted results, unavailable audit data, external effects and child obligations. |
| Handoff/custom participants | Establish their own supported preparation and ownership contracts. |

These remain in completion group 1. They are not relabeled as failed-Runtime or backend work to make the group appear complete. The next semantic resolution decision must preserve facts already accepted and define stable subject identity, revision binding, data-only replacement/abandonment rules and atomic responsibility transfer before implementation.
