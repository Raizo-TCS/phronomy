# Retain recovery responsibility across uncertain submission

Agent and Workflow must retain their original owner while a terminal save or recovery worker may still execute. A caller losing its submission response does not prove that the worker was rejected. G3b-4 applies the existing execution rejection evidence to Workflow initial saves and readback, and to Agent readback and captured-save retry.

For example, a custom execution adapter can enqueue a Workflow save and then lose the returned task handle. Releasing that Workflow would admit a replacement owner while the old save could still write. The corrected operation fails the caller observation with a recovery reference and retains the original responsibility.

## Distinguish mechanism facts from caller observations

The execution mechanism supplies admission and physical completion facts. The domain owner uses those facts to serialize its retained operation and to decide whether confirmed persistence can be applied. A closed caller observation does not release that obligation.

For example, a reconciliation read that is still queued may have no usable returned handle. Another explicit reconciliation request returns unavailable instead of starting a second read. A late value from the hidden worker does not establish physical completion of the executor task.

| Observed submission facts | Physical responsibility | Subsequent request |
| --- | --- | --- |
| Positive synchronous rejection, no returned handle, no worker entry | No worker obligation for this submission | Domain policy may end this failed attempt; a later explicit attempt can be considered. |
| Returned task handle, including a queued task | Retain until physical completion is observed | Join the same compatible attempt or inspect the retained handle; do not resubmit. |
| Worker entered but handle was lost | Retain without physical completion proof | Return unavailable; do not infer completion from a mailbox value. |
| Exception without positive rejection or a handle | Admission and physical completion are unresolved | Retain the operation and refuse another physical attempt. |

A returned handle or observed worker entry overrides a contradictory rejection notification. A backend must truthfully honor its opted-in rejection contract. A false notification followed by hidden future execution cannot be made safe by checking the current state of an unstarted block.

Agent's public `submission_state` continues to describe its terminal-work submission. It does not change when a later readback or captured-save retry is accepted or refused. Workflow does not acquire that public field or a new retry API.

## Preserve the domain-specific outcomes

The shared execution capability reports only whether work was refused. Agent and Workflow retain their different persistence, live-state and release policies. This change does not move their domain state into the execution pool.

For example, a positively rejected initial Workflow terminal save preserves its ordinary known-failure cleanup, whereas an Agent whose job has already completed its provider work retains that job for its existing explicit terminal-submission retry.

| Path | Positive refusal | Unknown admission |
| --- | --- | --- |
| Workflow initial terminal save | Original submission failure and ordinary known-failure cleanup | Typed terminal recovery failure; original owner and immutable save command retained. |
| Workflow reconciliation read | End this observation as unavailable; later explicit observation may submit again | Keep the current attempt; no second read or owner release. |
| Agent reconciliation read | End this observation as unavailable; later explicit observation may submit again | Keep the current attempt and original Agent owner. |
| Agent captured-save retry | End this observation as unavailable; later explicit retry may submit again | Keep the current attempt; no additional write or parser/encoder replay. |
| Agent initial save / first-submission recovery | Existing G3b-3 policy | Existing G3b-3 policy. |

Observer cancellation, timeout or failed callback registration does not invent rejection evidence. A returned task remains retained. Where its snapshot or completion callbacks can still establish physical completion, a fresh observation may finish the same attempt. Lost handles remain unavailable even after a worker publishes a value.

## Keep ordinary application source unchanged

The public operations and their arguments do not change. Applications still choose when to observe or explicitly retry, inspect the saved job status, and retain unresolved recovery references. The safety benefit is internal serialization and ownership retention rather than shorter application code.

For example, the same application can run an Agent analysis and a Workflow task before and after this change. Both normal runs produce the same normalized result and call counts. Failure behavior is intentionally different when a submission exception supplies no non-admission evidence.

<table class="source-comparison"><thead><tr><th>G3b-3</th><th>G3b-4</th></tr></thead><tbody><tr><td><pre><code>def run_report_application
  adapter = G3b4ReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  agent = G3b4ReportAgent.create(agent_id: &quot;g3b4-report&quot;, persistence: stores.agent)
  answer_task = agent.invoke_async(&quot;Prepare the report&quot;, output_schema: {
    type: &quot;object&quot;, properties: {answer: {type: &quot;string&quot;}},
    required: [&quot;answer&quot;], additionalProperties: false
  })
  answer = answer_task.wait_result(timeout: 5)
  resumed = agent.resume(answer.fetch(:execution_id))

  actions = {start: 0, apply: 0}
  workflow = Phronomy::Workflow.define(G3b4ReportContext, persistence: stores.workflow) do
    initial :formatting
    task_state :formatting,
      start: -&gt;(context) {
        actions[:start] += 1
        Phronomy::TaskResult.completed(context.answer.upcase)
      },
      apply: -&gt;(context, text) {
        actions[:apply] += 1
        context.merge(published_text: text)
      }
    transition from: :formatting, to: :__finish__
  end
  workflow_id = &quot;g3b4-report-publication&quot;
  publication_task = workflow.invoke_async({answer: answer.fetch(:output).fetch(&quot;answer&quot;)},
    config: {workflow_instance_id: workflow_id})
  publication = publication_task.wait_result(timeout: 5)

  {
    agent: agent, agent_task: answer_task, answer: answer, resumed: resumed,
    workflow: workflow, workflow_id: workflow_id, workflow_task: publication_task,
    publication: publication, stores: stores, adapter: adapter, actions: actions
  }
end</code></pre></td><td><pre><code>def run_report_application
  adapter = G3b4ReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  agent = G3b4ReportAgent.create(agent_id: &quot;g3b4-report&quot;, persistence: stores.agent)
  answer_task = agent.invoke_async(&quot;Prepare the report&quot;, output_schema: {
    type: &quot;object&quot;, properties: {answer: {type: &quot;string&quot;}},
    required: [&quot;answer&quot;], additionalProperties: false
  })
  answer = answer_task.wait_result(timeout: 5)
  resumed = agent.resume(answer.fetch(:execution_id))

  actions = {start: 0, apply: 0}
  workflow = Phronomy::Workflow.define(G3b4ReportContext, persistence: stores.workflow) do
    initial :formatting
    task_state :formatting,
      start: -&gt;(context) {
        actions[:start] += 1
        Phronomy::TaskResult.completed(context.answer.upcase)
      },
      apply: -&gt;(context, text) {
        actions[:apply] += 1
        context.merge(published_text: text)
      }
    transition from: :formatting, to: :__finish__
  end
  workflow_id = &quot;g3b4-report-publication&quot;
  publication_task = workflow.invoke_async({answer: answer.fetch(:output).fetch(&quot;answer&quot;)},
    config: {workflow_instance_id: workflow_id})
  publication = publication_task.wait_result(timeout: 5)

  {
    agent: agent, agent_task: answer_task, answer: answer, resumed: resumed,
    workflow: workflow, workflow_id: workflow_id, workflow_task: publication_task,
    publication: publication, stores: stores, adapter: adapter, actions: actions
  }
end</code></pre></td></tr></tbody></table>

The shared setup precedes the complete function above; the measurement and execution block follows it. Together these three units are the complete executable normal_application.rb. Run it from a checkout with dependencies installed and set both report paths. The deterministic adapter performs no network requests.

```ruby
# frozen_string_literal: true

# A deterministic report application. The fixture adapter performs no network
# request; the Agent and Workflow use the real Runtime and persistence stores.
require "phronomy"
require "json"

class G3b4ReportAdapter < Phronomy::LLMAdapter::Base
  attr_reader :requests

  def initialize
    @requests = 0
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @requests += 1
    Phronomy::LLMAdapter::Response.new(
      content: '{"answer":"report ready"}', finish_reason: :stop,
      usage: Phronomy::LLMAdapter::TokenUsage.new(input: 4, output: 2)
    )
  end
end

class G3b4ReportAgent < Phronomy::Agent::Base
  agent_definition id: "g3b4-report-agent", version: 1
end

class G3b4ReportContext
  include Phronomy::WorkflowContext

  field :answer, default: ""
  field :published_text, default: ""
end
```

```ruby
# Measurement is separate from the application operation. Repository reads here
# are evidence of persisted results; the application does not repair ownership.
def measure_report_application(run)
  answer = run.fetch(:answer)
  execution = run.fetch(:stores).agent.executions.load(answer.fetch(:execution_id))
  saved = run.fetch(:stores).workflow.load(run.fetch(:workflow_id))
  {
    agent: {
      output: answer.fetch(:output), resumed_output: run.fetch(:resumed).fetch(:output),
      raw_output: answer.fetch(:raw_output), usage: answer.fetch(:usage).to_h,
      durable_status: execution.status, durable_phase: execution.phase,
      durable_revision: execution.execution_revision,
      stored_result: run.fetch(:stores).agent.contents.fetch_text(execution.result_ref),
      root_status: run.fetch(:agent).agent_root.lifecycle_status,
      logical_complete: run.fetch(:agent_task).done?,
      physical_complete: run.fetch(:agent_task).physical_complete?,
      provider_calls: run.fetch(:adapter).requests
    },
    workflow: {
      answer: run.fetch(:publication).answer,
      published_text: run.fetch(:publication).published_text,
      revision: saved.fetch(:revision), snapshot: saved.fetch(:snapshot),
      logical_complete: run.fetch(:workflow_task).done?,
      physical_observation_available: run.fetch(:workflow_task).respond_to?(:physical_complete?),
      actions: run.fetch(:actions),
      pending_recovery: !run.fetch(:workflow).pending_terminal_recovery(
        workflow_instance_id: run.fetch(:workflow_id)
      ).nil?
    }
  }
end

if $PROGRAM_NAME == __FILE__
  begin
    run = run_report_application
    report = measure_report_application(run)
    raise "Unexpected Agent output" unless report[:agent][:output] == {"answer" => "report ready"}
    raise "Unexpected Workflow output" unless report[:workflow][:published_text] == "REPORT READY"
    raise "The provider was replayed" unless report[:agent][:provider_calls] == 1
    raise "The Workflow action was replayed" unless report[:workflow][:actions] == {start: 1, apply: 1}
    File.write(ENV.fetch("G3B4_APPLICATION_REPORT"), JSON.pretty_generate(report) + "\n")
    loaded_source = {
      application: method(:run_report_application).source_location,
      agent_operation: Phronomy::Agent::TerminalRecoveryOperation.instance_method(:start).source_location,
      workflow_operation: Phronomy::WorkflowTerminalOperation.instance_method(:start).source_location,
      gem: Gem.loaded_specs.fetch("phronomy").full_gem_path
    }
    File.write(ENV.fetch("G3B4_APPLICATION_SOURCE_REPORT"), JSON.pretty_generate(loaded_source) + "\n")
  ensure
    Phronomy.reset_runtime!
  end
end
```

```sh
G3B4_APPLICATION_REPORT=/absolute/path/to/report.json \
G3B4_APPLICATION_SOURCE_REPORT=/absolute/path/to/source.json \
bundle exec ruby /absolute/path/to/normal_application.rb
```


The comparison claims equivalence only for the described normal inputs, outputs, ordering, persistence and cleanup. It does not claim equivalence for lost-response faults. Those faults are covered separately by real Runtime tests with blocked workers and counted storage/provider/Tool calls.

## Preserve supported submission contracts

The built-in pool synchronously reports definite queue rejection through the existing optional capability. A legacy custom submitter receives its original keyword set and is called once. A submitter that cannot prove non-admission can still run ordinary work, but its ambiguous exception no longer permits Workflow release or forgetting a recovery attempt.

For example, the acceptance fixture wraps a real submitter, lets it accept work, then raises instead of returning its handle. This deliberately injects a failure beyond the built-in pool's normal return contract. It proves the owner safety behavior under that fault; it is not evidence that the built-in pool normally loses handles.

The inherited capability declaration is not a substitute for truthfulness. Custom wrappers that change submission semantics must preserve the synchronous rejection guarantee or opt out. No retry-on-ArgumentError is used to discover supported keywords.

## Reuse the mechanism without merging domain owners

Execution owns the optional rejection dispatcher and pool evidence. Agent and Workflow own their terminal commands, result interpretation, exact owner checks and release rules. The existing slot bookkeeping is reused within each owner rather than introducing another universal recovery manager.

For example, Workflow confirmed pre-state can permit release after retirement and application, while an Agent with an accepted job must retain responsibility for its explicit saved-byte retry. A shared manager that chose either policy would cross the domain boundary; a manager parameterized with every policy would still require the same decisions in both domains.

The common specification is the admission/observation/physical-completion protocol. Its neutral capability remains shared. Repeated slot plumbing is assessed separately from the two domain lifecycles; whole-owner extraction is not justified by similar method names or source line counts alone. Both canonical Contract SVGs and the source dependency graph are checked in the delivery evidence.

## Validate safety and bounded progress

Runtime tests and a finite state model distinguish actual queued/running work, the owner's knowledge, independent caller closure and physical completion. Progress is promised only with the explicit executor, owner and caller premises needed to observe completion; unknown lost handles have no automatic recovery promise.

For example, a model mutation that treats an absent handle as rejection must produce a counterexample in which another attempt is admitted while the old worker remains possible. Separate mutations treat mailbox publication as physical completion or discard an unknown attempt. Their expected violations check that the positive invariants are meaningful.

The model and reproduction instructions are under `spec/models/recovery_submission_custody/`. The delivery includes actual baseline defect probes, repaired acceptance results, ordinary application comparison, full local checks and the previous G3b-3 application/CI review. Focused counts overlap the full suites and must not be added to their totals.

This unit does not implement approval-resume recovery, dispatch recovery, replacement-Runtime takeover or process-crash recovery. G3a approval recovery is the next substantive functional unit: complete pre/post decision evidence, restoration of a confirmed pre-state, and once-only application of a confirmed post-state. Worker completion still does not prove remote transaction settlement; existing authoritative persistence ordering premises apply.
