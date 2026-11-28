# frozen_string_literal: true

# BEGIN shared_setup
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
# END shared_setup

# BEGIN normal_before
module InitialPreparationApplication
  module Before
    def self.run(session, input)
      owner = session.fetch(:runner) || session.fetch(:source)
      owner.invoke(input, config: session.fetch(:config))
    end
  end
end
# END normal_before

# BEGIN normal_after
module InitialPreparationApplication
  module After
    def self.run(session, input)
      owner = session.fetch(:runner) || session.fetch(:source)
      owner.invoke(input, config: session.fetch(:config))
    end
  end
end
# END normal_after

# BEGIN recovery_before
module InitialPreparationApplication
  module Before
    # The baseline has no retained initial-preparation recovery capability.
    # An uncertain initial save propagates; another invoke is a new request.
    def self.start(session, input)
      {state: :terminal, result: run(session, input)}
    end
  end
end
# END recovery_before

# BEGIN recovery_after
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
# END recovery_after

# BEGIN driver
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
# END driver
