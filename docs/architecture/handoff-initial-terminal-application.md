# Handoff initial terminal finalization in a complete application

Handoff owns the routing obligation between Agents; each Agent owns its execution and original local work. An unsuccessful initial Target can therefore have a durable result while its parent still needs a separate routing transition. Existing Runner progress operations now finish that transition after both exact Agents have released local mutation custody and the current durable chain still authorizes it.

For case-42, Intake transfers responsibility to Review. Review rejects the input before calling its Provider. The saved failure remains a failure. The Runner makes the current route stable, allowing the application to inspect the outcome, decide whether to keep history, and explicitly release completed history and unload the Agents.

## Behavioral contract

The comparison keeps application policy and execution semantics visible. Normal execution has equivalent inputs, output, ordering, session ownership, cancellation token, and explicit cleanup. The failure path intentionally gains parent completion and additional diagnostic handling; this is not an application line-count reduction.

For the successful case-42, both complete normal functions return the Review output after two offline Provider responses. For rejected case-42, Before raises the saved error but leaves routing unfinished; After raises the same saved error after routing completion, or exposes a separate unconfirmed-finalization diagnostic.

| Situation | Before at ae9fafde | After |
| --- | --- | --- |
| Ordinary transfer succeeds | Saved success, stable route | Same success and stable route |
| Initial Target fails, blocks, or is cancelled | Saved outcome; parent may remain pending | Same outcome; explicit progress finalizes the exact current parent |
| Reading result | Reads saved outcome | Reads saved outcome, without writes |
| Initial Agent custody is retained | Explicit U04 reconciliation is required | Same requirement before parent progress |
| Parent finalization reply is lost | No parent-finalization operation | Confirmed post-state is adopted; otherwise explicit diagnostic and later progress |
| History removal | Explicit and only after completion | Same policy; no automatic deletion |
| Unload fails after history removal | Application retains cleanup progress | Same retained flag prevents repeating successful history removal |

The Before application is an adaptation of existing APIs, executed against applied commit `ae9fafdebcdaaf954c9a3a80aab5221891ff0e31`. It contains no baseline implementation of the missing finalizer. The After application is exercised through the actual Runtime by `spec/phronomy/multi_agent/handoff_initial_terminal_application_spec.rb`. Both use the complete fixture below; no external model service is contacted.

## Shared session and initial recovery

The application owns one serialized session, its cancellation token, original recovery capabilities, and explicit cleanup progress. An observer timeout keeps the same task available; it does not authorize a second write or cancel the underlying work. Initial recovery and parent finalization remain separate decisions.

If Review's D2 failure save commits but its response is lost, the application discovers its original capability even when the saved failure is already readable. It reconciles that capability, waits for the fresh exact execution observation, and only then explicitly resumes the same Runner entry. The helper's execution-observation example is scoped to this saved D2 case. Other execution-observation errors propagate with the retained session and receipt.

The complete setup appears once and is shared by both columns. Agent definitions use unique IDs so this fixture can run beside the earlier initial-preparation example.

```ruby
# frozen_string_literal: true

require "phronomy"

module HandoffTerminalApplication
  class IntakeAgent < Phronomy::Agent::Base
    agent_definition id: "handoff-initial-terminal-intake-example", version: 1
    model "gpt-4o-mini"
    provider :openai
  end

  class ReviewAgent < Phronomy::Agent::Base
    agent_definition id: "handoff-initial-terminal-review-example", version: 1
    model "gpt-4o-mini"
    provider :openai
  end

  def self.open_session(handoff: false)
    stores = Phronomy::PersistenceComposition.in_memory
    source = IntakeAgent.create(persistence: stores.agent)
    target = handoff ? ReviewAgent.create(persistence: stores.agent) : nil
    edge = if target
      Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
    end
    runner = if edge
      Phronomy::MultiAgent::HandoffRunner.new(main_agent: source,
        persistence: stores.multi_agent, handoffs: [edge])
    end
    {stores: stores, source: source, target: target, edge: edge, runner: runner,
     agents: [source, target].compact.to_h { |agent| [agent.agent_id, agent] },
     config: {cancellation_token: Phronomy::Concurrency::CancellationToken.new},
     history_released: false}
  end

  # The application decides when terminal history is no longer needed.
  # Never unload a session while its preparation or execution is unresolved.
  def self.close_completed_session(session)
    unless session[:history_released]
      session.fetch(:runner)&.forget_history!
      session[:history_released] = true
    end
    session.fetch(:target)&.unload!
    session.fetch(:source).unload!
  end
end

module HandoffTerminalApplication
  def self.pending_initial(session)
    pending = session.fetch(:agents).values.filter_map(&:pending_initial_preparation_recovery)
    raise Phronomy::Error, "Select one initial obligation explicitly" if pending.size > 1
    pending.first
  end

  # U04 is already present in Before. These helpers do not retry captured writes.
  def self.begin_initial_recovery(session, pending)
    capability = pending.fetch(:recovery)
    task = session.fetch(:agents).fetch(capability.agent_id)
      .reconcile_initial_preparation_async(recovery: capability)
    pending.merge(state: :initial_waiting, task: task)
  end

  def self.wait_initial_recovery(pending, timeout: nil)
    task = pending.fetch(:task)
    receipt = task.wait_result(timeout: timeout)
    pending.merge(state: receipt.resolved? ? :initial_applied : :initial_pending, receipt: receipt, wait_error: nil)
  rescue Phronomy::TimeoutError => error
    raise if task.done?
    pending.merge(state: :initial_waiting, wait_error: error)
  end

  # This example's recovery case is a saved D2 failure. A different execution
  # observation error still propagates; the caller keeps the session and receipt.
  def self.wait_initial_execution(pending, timeout: nil)
    receipt = pending.fetch(:receipt)
    raise ArgumentError, "Initial custody is still pending" unless receipt.resolved?
    task = receipt.execution_task
    result = task.wait_result(timeout: timeout)
    pending.merge(state: :initial_settled, execution_result: result, wait_error: nil)
  rescue Phronomy::TimeoutError => error
    raise if task.done?
    pending.merge(state: :initial_execution_waiting, wait_error: error)
  end
end
```

## Complete normal source comparison

The normal call passes the same input and control token to the same session owner. The application marks history as retained for the new turn and receives the existing Runner result.

For accepted case-42, the following two functions execute the same Intake-to-Review transfer and return `case-42 reviewed`.

<table>
<tr><th>Before: applied U04</th><th>After: this change</th></tr>
<tr><td><pre><code>module HandoffTerminalApplication
  module Before
    def self.run(session, input)
      session[:history_released] = false
      session.fetch(:runner).invoke(input, config: session.fetch(:config))
    end
  end
end
</code></pre></td><td><pre><code>module HandoffTerminalApplication
  module After
    def self.run(session, input)
      session[:history_released] = false
      session.fetch(:runner).invoke(input, config: session.fetch(:config))
    end
  end
end
</code></pre></td></tr>
</table>

## Complete recovery source comparison

The application distinguishes a saved business error from an unconfirmed parent transition, retaining the identities and evidence needed for a later explicit decision. Initial custody takes precedence over parent progress. The added diagnostic branches preserve both errors rather than substituting a successful job result.

For rejected case-42 with a rolled-back routing save, After returns `routing_pending` with the exact requested entry, terminal Target ID, immutable saved result, original execution error, finalization error, optional read error, and disposition. A later call to the complete `resume` function is an explicit new routing-only attempt. Before has no equivalent parent-finalization diagnostic because that operation did not exist.

<table>
<tr><th>Before: applied U04</th><th>After: this change</th></tr>
<tr><td><pre><code>module HandoffTerminalApplication
  module Before
    def self.start(session, input)
      {state: :observed, execution_result: run(session, input)}
    rescue =&gt; error
      capture_error(session, error)
    end

    def self.resume(session, execution_id)
      result = session.fetch(:runner).resume(execution_id, config: session.fetch(:config))
      {state: :observed, execution_id: execution_id, execution_result: result}
    rescue =&gt; error
      capture_error(session, error, execution_id: execution_id)
    end

    def self.capture_error(session, error, execution_id: nil)
      capability = HandoffTerminalApplication.pending_initial(session)
      if capability
        {state: :initial_pending, recovery: capability, error: error,
         execution_id: execution_id || capability.execution_id}
      else
        {state: :operation_error, execution_id: execution_id, error: error}
      end
    end
  end
end
</code></pre></td><td><pre><code>module HandoffTerminalApplication
  module After
    def self.start(session, input)
      {state: :observed, execution_result: run(session, input)}
    rescue =&gt; error
      capture_error(session, error)
    end

    def self.resume(session, execution_id)
      result = session.fetch(:runner).resume(execution_id, config: session.fetch(:config))
      {state: :observed, execution_id: execution_id, execution_result: result}
    rescue =&gt; error
      capture_error(session, error, execution_id: execution_id)
    end

    def self.capture_error(session, error, execution_id: nil)
      capability = HandoffTerminalApplication.pending_initial(session)
      finalization = error.is_a?(Phronomy::MultiAgent::HandoffFinalizationError)
      entry_id = finalization ? error.execution_id : execution_id
      if capability
        return {state: :initial_pending, recovery: capability, error: error,
                execution_id: entry_id || capability.execution_id}
      end
      if finalization
        return {state: :routing_pending, execution_id: error.execution_id,
                target_execution_id: error.target_execution_id,
                main_agent_id: error.main_agent_id, execution_result: error.execution_result,
                execution_error: error.execution_error, finalization_error: error.finalization_error,
                read_error: error.read_error, disposition: error.disposition, error: error}
      end
      # A saved business failure remains an error, never a successful job.
      {state: :operation_error, execution_id: entry_id, error: error}
    end
  end
end
</code></pre></td></tr>
</table>

## Complete driver and offline dependency

The driver keeps the session reachable on errors and makes cleanup an explicit application action. Its deterministic Provider fixture supplies exactly the transfer and final output required by the example, so a replay is observable instead of silently obtaining another response.

Calling the fixture with `version: :after, reject: true` drives the exact rejected responsibility; `reject: false` drives the ordinary successful transfer. Cleanup returns `cleanup_pending` with the same session when either history removal or unloading fails. Once history removal has succeeded, a later cleanup attempt skips that completed step.

The driver is part of `spec/fixtures/handoff_initial_terminal/application.rb`; the following dependency is the entire `offline_fixture.rb` beside it. The fixture requires that complete application file. RSpec supplies only assertions and fault injection in the acceptance suite.

```ruby
module HandoffTerminalApplication
  # The caller serializes the session and explicitly selects further actions.
  def self.run_example(input, version: :after, session: nil)
    application = case version
    when :before then Before
    when :after then After
    else raise ArgumentError, "version must be before or after"
    end
    session ||= open_session(handoff: true)
    {session: session, application: application, observation: application.start(session, input)}
  rescue => error
    raise unless session
    {session: session, application: application, observation: {state: :operation_error, error: error}}
  end

  # No ensure block deletes history. A cleanup error keeps the same session.
  def self.close_example(work)
    close_completed_session(work.fetch(:session))
    work.merge(observation: {state: :closed})
  rescue => error
    work.merge(observation: {state: :cleanup_pending, error: error})
  end
end
```
```ruby
# frozen_string_literal: true

require_relative "application"

module HandoffTerminalApplication
  module OfflineFixture
    class RejectedResponsibility < Phronomy::Filter::Base
      def call(value, **_context)
        raise ArgumentError, "Review rejected case-42" if value == "reject case-42"
        value
      end
    end
    ReviewAgent.input_filter RejectedResponsibility

    class Adapter < Phronomy::LLMAdapter::Base
      attr_reader :requests

      def initialize(tool_name: nil, responsibility: nil, responses: nil)
        @requests = []
        @responses = responses || [
          Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
            Phronomy::Tool::CallRequest.new(id: "delegate-case-42", name: tool_name,
              arguments: {"responsibility" => responsibility})
          ]),
          Phronomy::LLMAdapter::Response.new(content: "case-42 reviewed", finish_reason: :stop)
        ]
      end

      protected

      def perform_complete(request, cancellation_token:)
        @requests << request
        @responses.shift || raise("unexpected Provider replay")
      end
    end

    # This complete fixture supplies deterministic Provider responses. It never
    # constructs an HTTP client or sends the model declaration to a live service.
    def self.run(version:, reject:)
      session = HandoffTerminalApplication.open_session(handoff: true)
      binding = Phronomy::MultiAgent::HandoffCapabilityFactory.build(session.fetch(:edge))
      adapter = Adapter.new(tool_name: binding.tool_name,
        responsibility: reject ? "reject case-42" : "review case-42")
      Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
      work = HandoffTerminalApplication.run_example("case-42", version: version, session: session)
      {work: work, adapter: adapter}
    end
  end
end
```

## Acceptance and scope

The application checks exercise live Runtime behavior with deterministic local Provider responses and real in-memory transactions. Domain proof and registry unit checks cover additional invalid-authority and unavailable-query branches; the bounded model is a separate verification layer, not a substitute for Runtime evidence.

For example, the acceptance suite blocks Target preparation physically while a concurrent cancellation returns, confirms that cleanup stays blocked, then releases that work and explicitly resolves initial custody when exposed. It also drives a normal two-transfer chain and verifies that the older Sources have released admission before the last Target fails.

| Boundary | Application evidence |
| --- | --- |
| Normal success and next turn | Complete Before/After functions, same output, explicit cleanup, new active-Target turn |
| Initial unsuccessful result | Filter, hook, Policy, cancelled, and blocked outcomes preserved; no Target Provider call or callback replay |
| Routing uncertainty | Pre-save rollback, post-commit response loss, unavailable confirmation read, explicit invoke/resume/cancel |
| Initial uncertainty and observation | D2 post-save custody, read-only result, explicit reconciliation, same-task observer timeout |
| Identity and concurrency | Changed authority after custody observation, stale old chain versus new pending chain, concurrent finalizers with one effective revision |
| Lifetime | Physically blocked preparation and concurrent cancel, retryable cleanup, explicit forget followed by a new main-Agent job |
| Normal multi-hop history | Older Sources released in the normally driven chain; explicit cleanup succeeds |

No helper retries automatically. `result` does not finalize; `forget_history!` does not repair pending routing. A saved failed, cancelled, or blocked Target does not become successful after cleanup. A later genuinely new job uses a new invocation identity. The serial application example does not promise safe concurrent application mutation of its session hash.

The multi-hop test proves the normally driven settled chain only. Immediate Source/Target custody observations do not establish that every possible historical owner is quiescent after independent reentry. That broader history-release correspondence remains open under U-01. Unsupported Store/Runtime observations and unknown current authority remain conservative errors; this change does not provide general recovery for them. Pending completed Targets, active/suspended work, arbitrary participant callbacks, and full distributed physical completion are outside this bounded repair.
