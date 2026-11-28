# Recovering an uncertain initial preparation

An initial request can lose the response to its admission save, first-manifest save,
or preparation-failure save. The original caller's failed observation does not prove
that the save failed. Starting another invocation would create another request; it
cannot repair the original admission.

The live Agent retains one initial-preparation obligation. Its capability identifies
that Agent, execution and recovery operation. `pending_initial_preparation_recovery`
needs no execution ID, because the original caller may never have received one.
Use the same live Agent and Runtime that accepted the request. This capability is
not a serialized restart recipe and does not replace ordinary durable recovery.

## Public observations and decisions

| API or field | Meaning |
| --- | --- |
| `pending_initial_preparation_recovery` | Discover the retained initial obligation, or `nil`. |
| `reconcile_initial_preparation(recovery:)` | Observe authoritative save evidence and continue established work. It does not retry an uncommitted save. |
| `retry_initial_preparation(recovery:)` | Recheck authority and retry only a complete captured proposal whose pre-state still matches. |
| Corresponding `_async` methods | Return a Task for this recovery observation. Cancelling that observer does not undo physical work. |
| `stage` | `:admission`, `:activation` or `:failure`; the same capability can advance between stages. |
| `outcome` | `:confirmed_pre`, `:confirmed_post`, `:not_prepared`, `:unresolved` or `:unavailable`. |
| `resolved?` | The initial obligation has been applied and handed over or stopped; the execution need not be terminal. |
| `physical_complete?` | The observed recovery attempt has physically completed. This alone does not authorize continuation. |
| `execution_task` | A fresh observation of that same execution after resolution. Saved failure or cancellation is a result Hash. If cancellation is confirmed before admission, no execution exists and this Task fails with the cancellation error. |
| `error` | Error in this recovery observation. A successfully reconciled saved preparation failure is represented in `execution_task`, not as a failed reconciliation. |

A confirmed admission may run input filters, the before-LLM hook and context Policy
for the first time. Confirming the first manifest reuses its captured preparation;
those callbacks are not repeated. If another save response is lost during this
continuation, retain the same capability and make a later explicit observation.
An unreadable or changed proof remains pending; the example does not spin or infer
success from elapsed time.
An opaque custom admission callback retains its ordinary successful behavior. If
initial processing becomes uncertain, including refusal of the completed worker's
notification, the framework cannot prove the callback's complete write set. Recovery
remains unavailable and never replays that arbitrary callback.

Parent cancellation and deadlines remain linked after the original observation
has closed. Later cancellation does not replace an already captured preparation
failure with a different terminal result. Cancellation can resolve a confirmed pre-admission obligation without
creating an execution, so inspect `resolved?` before choosing a retry. A read of an
already saved failure does not itself release the original admission. In particular,
a reserved exact observer can return a saved failure while recovery is still pending.

A partially installed initial projection is removable only when it matches the
retained original owner and the Runtime positively confirms that its exact session
was not admitted. This permits late cancellation to save its terminal result and
release the original slot after registration refusal. Unknown or admitted session
status does not authorize deleting the projection or stopping possibly live work.

The existing activation materialization path can turn an input-materialization
failure into a saved preparation failure. Recovery does not promise that all later
reads become separately retryable, nor does this API close the later Outcome-save
frontier.

## Complete shared application setup

These examples use one serialized application session with an in-memory store.
Configure the normal provider credentials before running them. The acceptance
spec replaces provider traffic with its existing HTTP stub; no live service is used.
The shared fixture, all functions below, and the driver are in
`spec/fixtures/initial_preparation_recovery/application.rb`.

```ruby
require "phronomy"

module InitialPreparationApplication
  class IntakeAgent < Phronomy::Agent::Base
    agent_definition id: "initial-preparation-intake-example", version: 1
    model "gpt-4o-mini"
    provider :openai
  end

  class ReviewAgent < Phronomy::Agent::Base
    agent_definition id: "initial-preparation-review-example", version: 1
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
     config: {cancellation_token: Phronomy::Concurrency::CancellationToken.new}}
  end

  # The application decides when terminal history is no longer needed.
  # Never unload a session while its preparation or execution is unresolved.
  def self.close_completed_session(session)
    session.fetch(:runner)&.forget_history!
    session.fetch(:target)&.unload!
    session.fetch(:source).unload!
  end
end
```

## Normal application before and after

The ordinary successful invocation remains the same. These are complete functions,
not wrappers around an omitted implementation.

Before:

```ruby
module InitialPreparationApplication
  module Before
    def self.run(session, input)
      owner = session.fetch(:runner) || session.fetch(:source)
      owner.invoke(input, config: session.fetch(:config))
    end
  end
end
```

After:

```ruby
module InitialPreparationApplication
  module After
    def self.run(session, input)
      owner = session.fetch(:runner) || session.fetch(:source)
      owner.invoke(input, config: session.fetch(:config))
    end
  end
end
```

## Recovery behavior before and after

The baseline function below propagates uncertainty. It is the complete baseline
application entry point, not a claim that the baseline implements this recovery API.
Its existing normal behavior is exercised against the applied U03 source.

Before:

```ruby
module InitialPreparationApplication
  module Before
    # The baseline has no retained initial-preparation recovery capability.
    # An uncertain initial save propagates; another invoke is a new request.
    def self.start(session, input)
      {state: :terminal, result: run(session, input)}
    end
  end
end
```

The candidate application retains pending observations and makes retry policy
explicit. `retry_confirmed_pre: false` returns control to the application. Setting it
to `true` permits at most one captured-save retry per call. The caller can observe
again later after examining the pending receipt; it must not call `start` again to
repair that work.

A Handoff Runner can surface a saved business failure without the typed initial
recovery exception. The example therefore also checks the live Agents' pending
capabilities. After cleanup, Runner observation preserves its existing saved-error
semantics, including wrapping a saved exception as `Phronomy::Error`. Unrelated
errors are propagated. No pending session is unloaded in a rescue or ensure block.

After:

```ruby
module InitialPreparationApplication
  module After
    def self.start(session, input, retry_confirmed_pre: false, wait_timeout: nil)
      # This example's caller serializes operations on one session. Previously
      # retained work must be passed to recover, never hidden by a new request.
      if pending_preparation(session)
        raise ArgumentError, "observe the existing initial preparation before starting another request"
      end
      begin
        result = run(session, input)
      rescue => failure
        recovery = if failure.is_a?(Phronomy::Agent::InitialPreparationRecoveryError)
          failure.recovery
        else
          pending_preparation(session)
        end
        raise unless recovery
        return recover(session, recovery, retry_confirmed_pre: retry_confirmed_pre,
          wait_timeout: wait_timeout).merge(original_observation_error: failure)
      end
      # Exact reserved observers can return a saved failure while the original
      # initial admission is still retained. Reading a result is not release.
      recovery = pending_preparation(session, execution_id: result[:execution_id])
      if recovery
        return recover(session, recovery, retry_confirmed_pre: retry_confirmed_pre,
          wait_timeout: wait_timeout)
      end
      {state: :terminal, result: result}
    end

    def self.pending_preparation(session, execution_id: nil)
      recoveries = session.fetch(:agents).values.filter_map(&:pending_initial_preparation_recovery)
      recoveries.select! { |recovery| recovery.execution_id == execution_id } if execution_id
      raise Phronomy::Error, "more than one initial obligation needs an explicit selection" if recoveries.size > 1
      recoveries.first
    end

    # Reading proof does not choose a save retry. This explicit policy permits
    # at most one retry of a complete proposal whose pre-state was confirmed.
    def self.recover(session, recovery, retry_confirmed_pre: false, wait_timeout: nil)
      agent = session.fetch(:agents).fetch(recovery.agent_id)
      receipt = agent.reconcile_initial_preparation(recovery: recovery)
      if !receipt.resolved? && receipt.outcome == :confirmed_pre && retry_confirmed_pre
        receipt = agent.retry_initial_preparation(recovery: recovery)
      end
      pending = {state: :recovery_pending, recovery: recovery, receipt: receipt}
      return pending unless receipt.resolved?
      finish(session, pending, wait_timeout: wait_timeout)
    end

    # This timeout bounds only the execution Task wait. It does not impose a
    # deadline on synchronous reconciliation or Handoff Runner continuation.
    def self.finish(session, pending, wait_timeout: nil)
      task = pending.fetch(:receipt).execution_task
      begin
        execution = task.wait_result(timeout: wait_timeout)
      rescue Phronomy::TimeoutError => error
        raise if task.done?
        return pending.merge(state: :execution_observation_pending, error: error)
      end
      runner = session.fetch(:runner)
      result = if runner
        runner.resume(pending.fetch(:recovery).execution_id, config: session.fetch(:config))
      else
        execution
      end
      {state: :terminal, result: result}
    end
  end
end
```

## Complete driver

This driver returns both the session and the observation so the caller keeps custody
of pending work. An exception from `After.start` becomes an explicit
`:application_error` observation containing the original error and the session;
it is never labeled successful. The caller decides how to report or re-raise it and
retains the handles needed for explicit cleanup. On `:recovery_pending`, retain the capability and call `After.recover`
when policy or restored evidence permits another observation. On
`:execution_observation_pending`, retain the receipt and call `After.finish` again.
That state reports only a local wait timeout; it does not cancel the execution.
A terminal failed/cancelled result remains terminal; it is not converted to success.
Call `close_completed_session` only when the execution and any initial obligation
are terminal/resolved and their Handoff history is no longer needed. A saved failed
Handoff target can still leave its routing phase unfinished even after this initial
obligation is released. The existing `forget_history!` then rejects cleanup with
`AgentBusyError`; retain the returned session. This example records that separate
Handoff routing limitation and does not claim to resolve it.

```ruby
module InitialPreparationApplication
  # A caller keeps session and any pending receipt until it decides to observe
  # again. Saved failure, cancellation and unrelated errors remain visible.
  def self.run_example(input, retry_confirmed_pre: false, handoff: false)
    session = open_session(handoff: handoff)
    begin
      observation = After.start(session, input, retry_confirmed_pre: retry_confirmed_pre)
    rescue => error
      observation = {state: :application_error, error: error}
    end
    {session: session, observation: observation}
  end
end
```

## Acceptance evidence

`spec/phronomy/agent/initial_preparation_recovery_application_spec.rb` exercises
real Runtime admissions and persistence with provider HTTP responses stubbed. It
covers all three initial save boundaries before and after commit, successive
admission/activation response loss, Handoff source and reserved-target recovery,
original observation closure, callback counts, parent cancellation and deadline
continuity, current routing authority, delayed physical work, observer cancellation,
notification refusal, structured output observation, saved-failure slot release,
and the complete application functions above. A recovery receipt and a terminal
job result are asserted separately.

The bounded formal model checks the initial-obligation protocol. Runtime tests
supply the concrete Ruby, persistence, callbacks and public API evidence. Neither
is evidence of exactly-once remote service effects or closure of later Outcome-save
uncertainty.
