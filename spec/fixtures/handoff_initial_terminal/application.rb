# BEGIN shared_setup
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
# END shared_setup

# BEGIN normal_before
module HandoffTerminalApplication
  module Before
    def self.run(session, input)
      session[:history_released] = false
      session.fetch(:runner).invoke(input, config: session.fetch(:config))
    end
  end
end
# END normal_before

# BEGIN normal_after
module HandoffTerminalApplication
  module After
    def self.run(session, input)
      session[:history_released] = false
      session.fetch(:runner).invoke(input, config: session.fetch(:config))
    end
  end
end
# END normal_after

# BEGIN recovery_before
module HandoffTerminalApplication
  module Before
    def self.start(session, input)
      {state: :observed, execution_result: run(session, input)}
    rescue => error
      capture_error(session, error)
    end

    def self.resume(session, execution_id)
      result = session.fetch(:runner).resume(execution_id, config: session.fetch(:config))
      {state: :observed, execution_id: execution_id, execution_result: result}
    rescue => error
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
# END recovery_before

# BEGIN recovery_after
module HandoffTerminalApplication
  module After
    def self.start(session, input)
      {state: :observed, execution_result: run(session, input)}
    rescue => error
      capture_error(session, error)
    end

    def self.resume(session, execution_id)
      result = session.fetch(:runner).resume(execution_id, config: session.fetch(:config))
      {state: :observed, execution_id: execution_id, execution_result: result}
    rescue => error
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
# END recovery_after

# BEGIN driver
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
# END driver
