# G3l: keep semantic ownership separate from persistence proof

## Framework decision

Agent owns the accepted execution and its full semantic outcome. Persistence evidence owns the captured record/content facts needed to classify and replay a save. Keeping those responsibilities distinct avoids converting application values merely to populate an unused proof mirror.

For example, a report has already encoded its output text. Its original output is a String subclass whose copying method raises. G3k unnecessarily copies that original output into detached proof data, so an otherwise complete save can become unavailable. The repair removes the unused copy; it does not ask for another report, invent replacement text or reduce the original outcome.

The baseline is applied G3k `5dc527ed82638d42f3aa8d7d00216fdebc239480`, tree `f4fbf854e00dc4671f664d5da62027f9e14dace9`. Contract concept v55 and foundation v48 are the diagram baseline. Final implementation acceptance and exact delivery identity are recorded separately.

**Decision:** remove private detached proof fields `result`, `error_diagnostic` and `approval_request` and the conversions used only to populate them. Keep the original semantic Outcome in `CapturedInput.values[:result]` and the retained owner's `@intended`; keep `execution_observation` decoded from exact captured content. No public API, recovery subject, result-abandonment action or new ownership state is introduced.

## Representation and consumer evidence

A representation is required only when a real consumer needs its facts. Similar names do not make the semantic Outcome used by the coordinator and the detached Outcome used by persistence the same contract.

For the report, the coordinator needs the complete messages, original output identity, usage and original error or approval object. Persistence replay needs the chosen root, execution and records. Public recovered execution observation needs the durable bytes, not a second copy of the live output object.

| Representation | Owner and consumer | Preserved contract |
| --- | --- | --- |
| `ExecutionOutcomeCommitter::Outcome` | Committer, retained recovery owner and coordinator | Full semantic outcome, ordinary result identity, messages/usage, original error and exact approval request |
| `TerminalPersistenceEvidence::Outcome` | Evidence replay and recovered execution observation | Exact root/execution/appended records and captured-byte `execution_observation` |
| `OutcomeRecoveryResult` | Application's new recovery observer | Persistence disposition, application/ownership states and the established saved-outcome shape |

At the baseline, no production reader of detached `result`, `error_diagnostic` or `approval_request` was found. Their consumers were private representation tests. `TerminalPersistenceEvidence#replay` reads records/execution/root; `OutcomeRecoveryOperation#remember_post` reads the proof's execution observation while retaining the original semantic Outcome. `apply_confirmation` sends that original Outcome to the coordinator. Tests must continue to assert the real contracts, rather than retain unused mirrors solely because a private test inspected them.

## Changed and unchanged behavior

Removing an unnecessary conversion removes an unnecessary failure point. It must not alter legitimate conversion, stored records or the responsibilities retained after genuinely incomplete preparation.

For the report, output encoding still happens once. A failed copy that existed only for the unused mirror now happens zero times. The Tool and Provider still execute their original counts, and ordinary publication still returns the original output object. A transient transcript read or a lost write response still uses the existing recovery APIs.

| Condition | G3k baseline | G3l behavior |
| --- | --- | --- |
| Ordinary supported result | Complete semantic result and captured persistence facts | Same public result and saved facts |
| Application-defined copy fails only in unused proof mirror | Complete encoded intent can remain unavailable | No unnecessary copy is invoked; the supported save can proceed |
| Duplicate diagnostic or approval conversion used only by proof mirror | Can run beyond the real semantic/encoding requirement | Removed; original error/request and captured observations remain with their actual consumers |
| Transcript hydration or persistence response fails | Existing retained preparation/proof recovery | Same APIs and guards; no additional business replay |
| Required encoder or genuine original diagnostic conversion fails | Preparation may be incomplete | Remains a separate group-1 issue; no forced terminalization |
| Wrong Store, stale owner, active physical attempt, conflicting state or revoked native authority | Responsibility remains retained | Same restrictions |

## Complete application comparison

The application requests and observes the same report through existing public APIs. It owns its persistence-retry policy and retains unresolved responsibility; it does not repair framework proof values. The before and after functions are byte-identical, while the explicitly identified copy-sensitive fault behavior changes.

For this example, a native-configured report parent makes two offline Provider calls and one Tool call. The Tool and Provider are counted fixtures, while the Agent, Runtime, transaction and retained owner are real. A declared child is not dispatched. The output can be a String whose custom copy method raises; its required text conversion still succeeds. The candidate should not call that copy solely to construct an unused mirror.

Copy shared setup, common observation helpers, one normal-function column, one recovery-function column, the fault fixture and shared driver into one Ruby file in that order. Run each case in a fresh process because the fault fixture instruments that process. This is an executable design example, not a separate application repository.

### Shared setup and observation

Both versions use the same report definitions, output object, storage and observations. The counters expose repeated business work and unnecessary copying; the observation helpers report real storage and retained responsibility rather than replacing the proof.

For the report, the full normal result can be compared with stored output and transcript, while a retained recovery error remains visible and prevents successful-cleanup claims.

<!-- g3l-code:shared-setup -->
```ruby
require "phronomy"
require "json"

class G3lReportError < Phronomy::Error
  def initialize
    super("The report source is unavailable", code: "report.source_unavailable")
  end
end

class G3lReportOutput
  def initialize(counts)
    @counts = counts
  end

  def to_s
    @counts[:output_conversion] += 1
    "Report completed"
  end
end

# This caller-owned value can be serialized but deliberately cannot be copied.
# A persistence proof needs its already encoded text, not another semantic copy.
class G3lUncopyableOutput < String
  def initialize(counts)
    super("Report completed")
    @counts = counts
  end

  def to_s
    @counts[:output_conversion] += 1
    super
  end

  def initialize_copy(_source)
    @counts[:custom_copy] += 1
    raise IOError, "The application output must not be copied"
  end
end

class G3lReportTool < Phronomy::Tool::Base
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

class G3lReportWorker < Phronomy::Agent::Base
  agent_definition id: "detached-proof-report-worker", version: 1
  model "offline-model"
end

class G3lReportParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "detached-proof-report-parent", version: 1
  model "offline-model"
  tools G3lReportTool => nil
  subagent :reviewer, G3lReportWorker
end

class G3lReportAdapter < Phronomy::LLMAdapter::Base
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

def build_report_service(failure: false, copy_sensitive: false)
  counts = Hash.new(0)
  error = failure ? G3lReportError.new : nil
  G3lReportTool.counts = counts
  adapter = G3lReportAdapter.new(counts, error: error)
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  parent = G3lReportParent.create(agent_id: "detached-proof-report-parent", persistence: stores.agent,
    coordination_store: stores.multi_agent)
  output = copy_sensitive ? G3lUncopyableOutput.new(counts) : G3lReportOutput.new(counts)
  parent.add_output_filter(->(_text) { output }) unless failure
  {counts: counts, stores: stores, parent: parent, output: output, error: error}
end
```

<!-- g3l-code:common-observation -->
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

### Ordinary call and copy-sensitive completion

The ordinary call waits for its existing result and performs cleanup only when the existing ownership contract permits it. Its use of the original output object and complete messages is the same on both sides.

For the report, ordinary success and source failure are compatibility controls. A copy-sensitive output is an intentional failure-behavior change: the baseline may retain responsibility because of the unnecessary mirror copy, whereas the candidate can finish without invoking it. This is not a claim that baseline and candidate fault outcomes are equivalent.

<table>
<thead><tr><th>Before: applied G3k</th><th>After: G3l</th></tr></thead>
<tbody><tr>
<td><pre><code><!-- g3l-code:normal-function:before -->def run_report(failure: false, copy_sensitive: false)
  service = build_report_service(failure: failure, copy_sensitive: copy_sensitive)
  report_fault(read_failure: :none, save_loss: :none).call(service)
  original = start_report(service)
  result = nil
  original_error = nil
  recovery_error = nil
  begin
    result = original.wait_result(timeout: 8)
  rescue G3lReportError =&gt; error
    original_error = error
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    recovery_error = error
  end
  if recovery_error
    recovery = recovery_error.recovery
    raise &quot;Unexpected retained owner&quot; unless service.fetch(:parent)
      .pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
    return {state: :retained, stored: stored_report(service), counts: service.fetch(:counts),
      original_output_preserved: nil, complete_result_messages_match_transcript: nil,
      original_business_error_preserved: nil, released: false,
      retained_service: service, retained_recovery: recovery}
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
<td><pre><code><!-- g3l-code:normal-function:after -->def run_report(failure: false, copy_sensitive: false)
  service = build_report_service(failure: failure, copy_sensitive: copy_sensitive)
  report_fault(read_failure: :none, save_loss: :none).call(service)
  original = start_report(service)
  result = nil
  original_error = nil
  recovery_error = nil
  begin
    result = original.wait_result(timeout: 8)
  rescue G3lReportError =&gt; error
    original_error = error
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    recovery_error = error
  end
  if recovery_error
    recovery = recovery_error.recovery
    raise &quot;Unexpected retained owner&quot; unless service.fetch(:parent)
      .pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
    return {state: :retained, stored: stored_report(service), counts: service.fetch(:counts),
      original_output_preserved: nil, complete_result_messages_match_transcript: nil,
      original_business_error_preserved: nil, released: false,
      retained_service: service, retained_recovery: recovery}
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

### Recovery policy after a failed observation

The recovery policy treats a fresh reconciliation as observation of retained responsibility. Only the explicit flag permits a captured-write retry after confirmed pre-state; the original Provider, Tool and closed invocation are never restarted.

For the report, a transient transcript read can be followed by the same existing reconciliation and explicit retry. A lost write response can instead be recognized as committed. Declining the retry remains a retained outcome and is reported as such.

<table>
<thead><tr><th>Before: applied G3k</th><th>After: G3l</th></tr></thead>
<tbody><tr>
<td><pre><code><!-- g3l-code:recovery-function:before --># Retrying a confirmed pre-state is an explicit persistence policy. It does not
# authorize repeating the report, output conversion or native preparation.
def run_report_with_recovery(fault:, retry_confirmed_pre: false, late_observer: false, copy_sensitive: false)
  service = build_report_service(copy_sensitive: copy_sensitive)
  fault.call(service)
  parent = service.fetch(:parent)
  original = start_report(service)
  original_failure = nil
  begin
    original.wait_result(timeout: 8)
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    original_failure = error
  end
  raise &quot;Expected an ambiguous report observation&quot; unless original_failure
  recovery = original_failure.recovery
  raise &quot;Unexpected retained owner&quot; unless parent.pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
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
    raise &quot;Original failed observation reopened&quot;
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    raise &quot;Original observation changed&quot; unless error.equal?(original_failure)
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
<td><pre><code><!-- g3l-code:recovery-function:after --># Retrying a confirmed pre-state is an explicit persistence policy. It does not
# authorize repeating the report, output conversion or native preparation.
def run_report_with_recovery(fault:, retry_confirmed_pre: false, late_observer: false, copy_sensitive: false)
  service = build_report_service(copy_sensitive: copy_sensitive)
  fault.call(service)
  parent = service.fetch(:parent)
  original = start_report(service)
  original_failure = nil
  begin
    original.wait_result(timeout: 8)
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    original_failure = error
  end
  raise &quot;Expected an ambiguous report observation&quot; unless original_failure
  recovery = original_failure.recovery
  raise &quot;Unexpected retained owner&quot; unless parent.pending_outcome_recovery(execution_id: service.fetch(:execution_id)).equal?(recovery)
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
    raise &quot;Original failed observation reopened&quot;
  rescue Phronomy::Agent::OutcomeRecoveryError =&gt; error
    raise &quot;Original observation changed&quot; unless error.equal?(original_failure)
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

### Fault fixture and complete driver

The fixture injects bounded failures into the real content/transaction path and supplies deterministic input objects. It leaves the real persistence proof, owner fencing and result publication in control of the outcome.

For the report, the copy-sensitive post-response case does not even reach the planned write fault on the baseline: the earlier redundant copy blocks it. The candidate can reach that fault and recover the actual committed result. The driver checks the expected behavior for the selected version and reports held responsibility rather than treating process exit as cleanup.

<!-- g3l-code:fault-fixture -->
```ruby
# The fixture counts actual terminal preparation and fails an actual immutable
# content read or a real transaction response. It never supplies an outcome.
module G3lReportFault
  class << self
    attr_accessor :current

    def report
      return {enabled: false} unless current
      current.slice(:read_failure, :save_loss, :read_failures, :save_failures,
        :committer_calls, :encoder_calls, :materialization_calls)
    end
  end
end

module G3lCommitScope
  def commit_outcome(command, **options)
    fault = G3lReportFault.current
    selected = fault && command.root.agent_id == fault.fetch(:service).fetch(:parent).agent_id
    previous = Thread.current[:g3l_report_outcome]
    Thread.current[:g3l_report_outcome] = selected ? fault : nil
    if selected
      fault.fetch(:service)[:execution_id] = command.execution_id
      fault[:committer_calls] += 1
    end
    super
  ensure
    Thread.current[:g3l_report_outcome] = previous
  end
end

module G3lEncodingCount
  def encode(*args, **options)
    fault = Thread.current[:g3l_report_outcome]
    fault[:encoder_calls] += 1 if fault
    super
  end
end

module G3lTranscriptScope
  def materialize_transcript(root:, records:)
    fault = G3lReportFault.current
    selected = fault && root.agent_id == fault.fetch(:service).fetch(:parent).agent_id
    previous = Thread.current[:g3l_report_transcript]
    Thread.current[:g3l_report_transcript] = selected ? fault : nil
    fault[:materialization_calls] += 1 if selected
    super
  ensure
    Thread.current[:g3l_report_transcript] = previous
  end
end

module G3lTranscriptRead
  def fetch(reference)
    fault = Thread.current[:g3l_report_transcript]
    should_fail = fault && fault.fetch(:service).fetch(:counts)[:output_conversion] > 0 &&
      (fault[:read_failure] == :permanent || (fault[:read_failure] == :once && fault[:read_failures].zero?))
    if should_fail
      fault[:read_failures] += 1
      raise IOError, "Immutable report transcript content is unavailable"
    end
    super
  end
end

module G3lSaveResponse
  def atomic(*args, &transaction)
    fault = Thread.current[:g3l_report_outcome]
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

Phronomy::Agent::ExecutionOutcomeCommitter.prepend(G3lCommitScope)
Phronomy::Agent::RuntimeRecordEncoder.singleton_class.prepend(G3lEncodingCount)
Phronomy::Agent::RuntimeInput.prepend(G3lTranscriptScope)
Phronomy::Persistence::ContentRepository.prepend(G3lTranscriptRead)

def report_fault(read_failure:, save_loss:)
  raise ArgumentError, "Unknown read failure" unless %i[none once permanent].include?(read_failure)
  raise ArgumentError, "Unknown response loss" unless %i[none pre post].include?(save_loss)
  lambda do |service|
    service.fetch(:stores).agent.coordinator.singleton_class.prepend(G3lSaveResponse)
    G3lReportFault.current = {service: service, read_failure: read_failure, save_loss: save_loss,
      save_armed: true, readback_loss: false, read_failures: 0, save_failures: 0,
      committer_calls: 0, encoder_calls: 0, materialization_calls: 0}
  end
end
```

<!-- g3l-code:shared-driver -->
```ruby
# An unresolved result retains the live owner and exact capability. A service
# must keep these values; process exit is not a handoff or recovery mechanism.
def run_report_example(normal: false, failure: false, read_failure: :none,
  save_loss: :none, retry_confirmed_pre: false, late_observer: false, copy_sensitive: false)
  begin
    report = if normal
      run_report(failure: failure, copy_sensitive: copy_sensitive)
    else
      run_report_with_recovery(fault: report_fault(read_failure: read_failure, save_loss: save_loss),
        retry_confirmed_pre: retry_confirmed_pre, late_observer: late_observer, copy_sensitive: copy_sensitive)
    end
    report = report.reject { |key, _value| %i[retained_service retained_recovery retained_observer].include?(key) }
  ensure
    fixture = G3lReportFault.report
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
  puts JSON.pretty_generate(run_report_example(normal: ENV["G3L_NORMAL"] == "true",
    failure: ENV["G3L_FAILURE"] == "true", read_failure: ENV.fetch("G3L_READ_FAILURE", "none").to_sym,
    save_loss: ENV.fetch("G3L_SAVE_LOSS", "none").to_sym,
    retry_confirmed_pre: ENV["G3L_RETRY_CAPTURED_OUTCOME"] == "true",
    late_observer: ENV["G3L_LATE_OBSERVER"] == "true",
    copy_sensitive: ENV["G3L_COPY_SENSITIVE"] == "true"))
end
```

## Minimal implementation and architecture

The implementation should narrow the private proof representation and remove only its redundant work. It should not add normalization machinery, reconstruct semantic output from stored text or relax immutable persistence evidence.

For the report, using captured output text as a replacement for the original semantic output would change ordinary identity and possibly the result shape. That substitution is unnecessary because the semantic Outcome is already retained. The proof's captured execution observation remains a separate public projection.

Required source changes are the private Data fields and their construction, matching RBS declarations, and tests that previously asserted unused mirrors. Runtime tests must demonstrate the removed callback, complete normal results, actual recovered observations and retained guards. The current owner/preparation lifecycle and existing one-shot protections need not be broadened. Final source review must confirm no production dynamic use of the removed fields.

No domain responsibility moves between Agent, MultiAgent, Persistence and Execution. Native child authority, retained holds and transaction guards stay with their current owners. Both Contract SVGs require final-source dependency review; the expected decision is no revision because this removes private Agent work rather than introducing a new contract or dependency direction.

## Symmetry and alternatives

Recovery operations are symmetric when their authority is the same, not merely when they have similar names. This change preserves existing operations because no new authority is needed.

For the report, reconciliation still classifies captured facts and explicit retry still writes them. A new API asking the application to resupply known text would add work for the caller and obscure an internal duplication defect.

| Peer or alternative | Decision | Reason |
| --- | --- | --- |
| Ordinary invoke versus recovered publication | Preserve their existing distinct shapes | Ordinary semantic output and exact durable observation are not interchangeable |
| Sync versus async outcome recovery | Unchanged | Both use the same original owner and physical lane |
| Terminal versus approval/coordination outcome | Preserve their domain-specific owner values | Unused mirrors do not justify repeating diagnostics or request conversion |
| Generic deep-copy rewrite | Reject for this change | Shared copy behavior has other consumers; remove work with no consumer first |
| Data supplied by application | Unnecessary for this defect | The useful facts already exist |
| Automatic failure/abandonment | Reject as a consequence of this cleanup | It would select new job semantics and could discard effect/child obligations |
| New state diagram or model family | Not needed for this change | No new actor, state or permitted transition is introduced |

## Validation and residual closure

Validation must show actual observable preservation and removal of the needless failure. A passing private constructor test alone does not show that the complete result is still published correctly.

For the report, use a String subclass whose copy method raises or records a call, while its required text encoding succeeds. Compare the exact baseline and candidate through real Runtime, original invocation, recovery and Store. Count actual callbacks and compare original identity, messages, durable observation and cleanup responsibility.

Required checks include normal success/failure, copy-sensitive normal completion, recovery after transcript-read or write-response loss, original closed-observer behavior, exact late-observer shape, no-retry retention, and unchanged current-authority/physical/store guards. Direct proof tests must verify captured observation immutability and preserve complete original semantic values. Diagnostic and approval cases must distinguish a genuinely required first conversion from the removed redundant one.

The complete application comparison ran six cases on each exact source version, with all six matching each version's expected behavior. The three copy-sensitive baseline cases retained responsibility; the candidate completed normal save or the applicable recovery path, with the unnecessary custom-copy count changing from one to zero. Ordinary success and source-failure control reports match exactly, and the explicit no-retry case remains retained. The runs bind 408 production source files per version and record actual loaded paths. Executing the same twelve combinations directly from the published eight code units produced the same reports; those twelve runs establish document correspondence, not twelve additional scenarios. Independent Runtime and complete regression evidence are recorded separately. These are local candidate results; hosted application and CI acceptance remain separate.

The existing finite model remains an abstract model of preparation, proof, original ownership, physical work and guarded persistence. Removing a redundant representation does not add a model transition. Any rerun/reuse is recorded with exact model inputs; neither the model nor the test counts prove Ruby refinement. The old copy-failure example remains historical evidence of the baseline, not a required permanent failure of the repaired candidate.

| Group-1 class | G3l effect | Remaining closure requirement |
| --- | --- | --- |
| Unused semantic proof copies/conversions | Eliminated where source and runtime evidence establish no consumer | Preserve actual owner semantics and exact proof facts |
| Fixed hydration after encoded intent | Existing G3k route retained | Preserve its guards and accepted evidence |
| Genuine pre-capsule encoding, output conversion or diagnostic failure | Not solved by removing mirrors | Define exact missing information and a supported completion/disposition contract |
| Partial encoding | Not made replayable | Preserve completed pieces/identities before permitting any later work |
| Pre-conversion framework reads/native planning | No new whole-stage retry | Define where fixed reads end and one-time semantic selection starts |
| Handoff/custom participants | No generalized guarantee | Audit actual existing guarantees and repair justified gaps |

Intentional abandonment and application-authoritative completion remain separate policy work. A separate deferred policy design explores those choices; no proposed completion or abandonment API is part of G3l. Group 1 and G3 overall remain incomplete. The existing six-group closure plan is unchanged; unfinished preparation work must not be moved into stopped-Runtime or backend acceptance merely to close G3.
