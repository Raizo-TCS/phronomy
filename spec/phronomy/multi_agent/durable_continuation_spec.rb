# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Durable continuation decisions" do
  include_context "durable coordination runtime"

  it "preserves worker failure across F4 after assignment settlement with on_error raise", :aggregate_failures do
    worker.input_filter Class.new(Phronomy::Filter::Base) {
      def call(_value, **_context) = raise("review worker failed")
    }
    team = team_class.create(team_id: "review-worker-failure", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      captured = backend.snapshot if !captured && run&.active? && run.assignments.any? { |a| a["error_ref"] }
    end
    LLMStub.activate(responses: team_responses)
    expect { team.invoke("plan") }.to raise_error(Phronomy::Error, /review worker failed/)
    expect(captured).not_to be_nil
    restored = reboot(captured)
    loaded = team_class.load(team.team_id, persistence: restored)
    run = loaded.executions.first
    llm = LLMStub.activate(responses: ["must not execute"])
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /review worker failed/)
    expect(loaded.result(run.team_execution_id)[:status]).to eq("failed")
    cancelled_store = reboot(captured)
    cancelled = team_class.load(team.team_id, persistence: cancelled_store)
    cancelled.cancel(run.team_execution_id)
    expect { cancelled.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /review worker failed/)
    expect(cancelled.executions.first.status).to eq("failed")
    expect(llm.calls).to be_empty
  end

  it "preserves coordinator failure across F4 after phase workers commit", :aggregate_failures do
    team = team_class.create(team_id: "review-coordinator-failure", persistence: store)
    allow(team).to receive(:coordinator_class).and_wrap_original do |original, id|
      klass = original.call(id)
      klass.input_filter Class.new(Phronomy::Filter::Base) {
        def call(_value, **_context) = raise("review coordinator failed")
      }
      klass
    end
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      captured = backend.snapshot if !captured && run&.active? && run.phase == "workers" && run.coordinator["error_ref"]
    end
    LLMStub.activate(responses: ["must not execute"])
    expect { team.invoke("plan") }.to raise_error(Phronomy::Error, /review coordinator failed/)
    expect(captured).not_to be_nil
    restored = reboot(captured)
    loaded = team_class.load(team.team_id, persistence: restored)
    run = loaded.executions.first
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /review coordinator failed/)
    expect(loaded.result(run.team_execution_id)[:status]).to eq("failed")
    cancelled_store = reboot(captured)
    cancelled = team_class.load(team.team_id, persistence: cancelled_store)
    cancelled.cancel(run.team_execution_id)
    expect { cancelled.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /review coordinator failed/)
    expect(cancelled.executions.first.status).to eq("failed")
  end

  it "resolves only external facts after restoring a mixed Provider response" do
    effects = 0
    external = Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "review_external"
      description "Application external effect"
      define_method(:execute) {
        effects += 1
        "external result"
      }
    end
    parent_class.tools(parent_class.tools.to_h { |tool| [tool, nil] }.merge(external => nil))
    parent = parent_class.create(agent_id: "review-mixed-provider", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_executions(parent.agent_id).first
      captured = backend.snapshot if !captured && run&.phase == :calling_llm
    end
    names = [["review_external", {}], ["dispatch_to_worker", {"input" => "job"}]]
    calls = names.each_with_index.map do |(name, args), i|
      {"id" => "review-mixed-#{i}", "type" => "function", "function" => {"name" => name, "arguments" => JSON.generate(args)}}
    end
    response = {"id" => "review-mixed", "object" => "chat.completion", "model" => "stub-model",
                "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => nil, "tool_calls" => calls}, "finish_reason" => "tool_calls"}]}
    LLMStub.activate(responses: [response, "child result", "parent result"])
    parent.invoke("plan")
    expect(captured).not_to be_nil
    expect(effects).to eq(1)
    restored = reboot(captured)
    events = Queue.new
    LLMStub.activate(responses: ["child recovered", "parent recovered"])
    loaded = parent_class.load(parent.agent_id, persistence: restored,
      on_event: ->(event) { events << event if event.type == :recovery_resolution_required })
    event = Timeout.timeout(3) { events.pop }.payload
    outcome = Phronomy::Agent::ProviderCallOutcome.new(role: :assistant, content: nil,
      tool_calls: names.each_with_index.map { |(name, args), i| {"id" => "review-mixed-#{i}", "name" => name, "arguments" => args} })
    loaded.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
      subject: event.fetch(:subject), outcome: :succeeded, result: outcome.to_h).wait_result(timeout: 3)
    event = Timeout.timeout(3) { events.pop }.payload
    expect(event.fetch(:facts).fetch(:tool_name)).to eq("review_external")
    result = loaded.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
      subject: event.fetch(:subject), outcome: :succeeded, result: "external result").wait_result(timeout: 3)
    remaining = []
    remaining << events.pop.payload until events.empty?
    expect(remaining.map { |p| p.fetch(:facts)[:tool_name] }).not_to include("dispatch_to_worker")
    expect(result[:output]).to eq("parent recovered")
    expect(effects).to eq(1)
  end

  it "preserves Team cancellation while an admitted worker is cancelled", :aggregate_failures do
    team = team_class.create(team_id: "recheck-worker-cancel", persistence: store)
    worker.input_filter Class.new(Phronomy::Filter::Base) {
      define_method(:call) do |value, **_context|
        team.cancel(team.executions.first.team_execution_id)
        value
      end
    }
    LLMStub.activate(responses: team_responses)
    expect { team.invoke("plan") }.to raise_error(Phronomy::CancellationError)
    run = team.executions.first
    expect(run.assignments.first.fetch("state")).to eq("cancelled")
    expect(run.metadata["cancel_requested"]).to be(true)
    expect(team.result(run.team_execution_id)[:status]).to eq("cancelled")
  end

  it "preserves Team cancellation while its admitted coordinator is cancelled", :aggregate_failures do
    team = team_class.create(team_id: "recheck-coordinator-cancel", persistence: store)
    allow(team).to receive(:coordinator_class).and_wrap_original do |original, id|
      klass = original.call(id)
      klass.input_filter Class.new(Phronomy::Filter::Base) {
        define_method(:call) do |value, **_context|
          team.cancel(team.executions.first.team_execution_id)
          value
        end
      }
      klass
    end
    LLMStub.activate(responses: ["must not execute"])
    expect { team.invoke("plan") }.to raise_error(Phronomy::CancellationError)
    run = team.executions.first
    expect(run.coordinator.fetch("state")).to eq("cancelled")
    expect(run.metadata["cancel_requested"]).to be(true)
    expect(team.result(run.team_execution_id)[:status]).to eq("cancelled")
  end
  it "continues pending framework calls after a second crash at external resolution commit", :aggregate_failures do
    effects = 0
    external = Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "review_external"
      description "Application external effect"
      define_method(:execute) {
        effects += 1
        "external result"
      }
    end
    parent_class.tools(parent_class.tools.to_h { |tool| [tool, nil] }.merge(external => nil))
    parent = parent_class.create(agent_id: "review-mixed-provider", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_executions(parent.agent_id).first
      captured = backend.snapshot if !captured && run&.phase == :calling_llm
    end
    names = [["review_external", {}], ["dispatch_to_worker", {"input" => "job"}]]
    calls = names.each_with_index.map do |(name, args), i|
      {"id" => "review-mixed-#{i}", "type" => "function", "function" => {"name" => name, "arguments" => JSON.generate(args)}}
    end
    response = {"id" => "review-mixed", "object" => "chat.completion", "model" => "stub-model",
                "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => nil, "tool_calls" => calls}, "finish_reason" => "tool_calls"}]}
    LLMStub.activate(responses: [response, "child result", "parent result"])
    parent.invoke("plan")
    expect(captured).not_to be_nil
    expect(effects).to eq(1)
    restored = reboot(captured)
    events = Queue.new
    LLMStub.activate(responses: ["child recovered", "parent recovered"])
    loaded = parent_class.load(parent.agent_id, persistence: restored,
      on_event: ->(event) { events << event if event.type == :recovery_resolution_required })
    event = Timeout.timeout(3) { events.pop }.payload
    outcome = Phronomy::Agent::ProviderCallOutcome.new(role: :assistant, content: nil,
      tool_calls: names.each_with_index.map { |(name, args), i| {"id" => "review-mixed-#{i}", "name" => name, "arguments" => args} })
    loaded.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
      subject: event.fetch(:subject), outcome: :succeeded, result: outcome.to_h).wait_result(timeout: 3)
    event = Timeout.timeout(3) { events.pop }.payload
    expect(event.fetch(:facts).fetch(:tool_name)).to eq("review_external")
    after_external_resolution = nil
    restored.after_commit = proc do |backend|
      run = backend.executions.load(event.fetch(:execution_id))
      if !after_external_resolution && run.phase == :recovery_tools_completed && run.metadata["framework_calls_pending"]
        after_external_resolution = backend.snapshot
      end
    end
    result = loaded.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
      subject: event.fetch(:subject), outcome: :succeeded, result: "external result").wait_result(timeout: 3)
    remaining = []
    remaining << events.pop.payload until events.empty?
    expect(remaining.map { |p| p.fetch(:facts)[:tool_name] }).not_to include("dispatch_to_worker")
    expect(result[:output]).to eq("parent recovered")
    expect(effects).to eq(1)
    expect(after_external_resolution).not_to be_nil
    restored_again = reboot(after_external_resolution)
    llm = LLMStub.activate(responses: ["worker after second restart", "parent after second restart"])
    loaded_again = parent_class.load(parent.agent_id, persistence: restored_again)
    final = loaded_again.resume(event.fetch(:execution_id))
    expect(final[:output]).to eq("parent after second restart")
    expect(llm.calls.size).to eq(2)
    run = restored_again.executions.load(event.fetch(:execution_id))
    coordination_ref = run.metadata["multi_agent_coordination_ref"]
    expect(coordination_ref).not_to be_nil
    expect(effects).to eq(1)
  end
  # Each entry drives real Provider/Tool sessions, captures every Recovery fact
  # commit, and resumes those records in a fresh Runtime/backend.
  [[], [:external], [:worker], [:external, :worker], [:worker, :external], [:external, :worker, :external]].product([false, true]).each do |composition, lose_commit_response|
    it "continues #{composition.inspect} after each Recovery commit (F1=#{lose_commit_response})" do
      effects = 0
      external = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "matrix_external"
        description "Application external effect"
        define_method(:execute) {
          effects += 1
          "external result"
        }
      end
      parent_class.tools(parent_class.tools.to_h { |tool| [tool, nil] }.merge(external => nil))
      names = composition.map { |kind| (kind == :worker) ? ["dispatch_to_worker", {"input" => "job"}] : ["matrix_external", {}] }
      calls = names.each_with_index.map { |(name, args), i| {"id" => "matrix-#{i}", "name" => name, "arguments" => args} }
      outcome = Phronomy::Agent::ProviderCallOutcome.new(role: :assistant,
        content: calls.empty? ? "resolved output" : nil, tool_calls: calls)
      response = {"id" => "matrix", "object" => "chat.completion", "model" => "stub-model",
                  "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => outcome.content,
                                                             "tool_calls" => calls.map { |call|
                                                               {"id" => call.fetch("id"), "type" => "function",
                                                                "function" => {"name" => call.fetch("name"), "arguments" => JSON.generate(call.fetch("arguments"))}}
                                                             }},
                                 "finish_reason" => calls.empty? ? "stop" : "tool_calls"}]}
      parent = parent_class.create(agent_id: "matrix-parent", persistence: store)
      before_response = nil
      store.after_commit = proc do |backend|
        run = backend.list_executions(parent.agent_id).first
        before_response ||= backend.snapshot if run&.phase == :calling_llm
      end
      followups = composition.include?(:worker) ? ["worker result", "parent result"] : ["parent result"]
      LLMStub.activate(responses: [response, *followups])
      parent.invoke("plan")
      expect(before_response).not_to be_nil
      expected_effects = composition.count(:external)
      expect(effects).to eq(expected_effects)

      restored = reboot(before_response)
      snapshots = {}
      restored.after_commit = proc do |backend|
        run = backend.list_executions(parent.agent_id).first
        lose_response = false
        if %i[recovery_provider_completed recovery_tools recovery_tools_completed].include?(run.phase)
          subjects = run.metadata.dig("recovery", "subjects") || []
          key = [run.phase, subjects.count { |subject| subject["state"] == "resolved" }]
          lose_response = lose_commit_response && !snapshots.key?(key)
          snapshots[key] ||= backend.snapshot
        end
        if run.phase == :dispatching_tools && (ref = run.metadata["multi_agent_coordination_ref"])
          slot = backend.contents.fetch_json(ref).fetch("children").first
          begin
            child = backend.executions.load(slot.fetch("execution_id"))
            snapshots[:child_terminal] ||= backend.snapshot if child.terminal?
          rescue Phronomy::Persistence::NotFoundError
            snapshots[:child_reserved] ||= backend.snapshot
          end
        end
        raise IOError, "resolution commit response lost" if lose_response
      end
      events = Queue.new
      llm = LLMStub.activate(responses: followups)
      loaded = parent_class.load(parent.agent_id, persistence: restored,
        on_event: ->(event) { events << event.payload if event.type == :recovery_resolution_required })
      id = restored.list_executions(parent.agent_id).first.execution_id
      resolve_matrix_facts(loaded, events, outcome)
      expect(loaded.resume(id)[:output]).to eq(calls.empty? ? "resolved output" : "parent result")
      expect(llm.calls.size).to eq(calls.empty? ? 0 : followups.size)
      if expected_effects.zero?
        expect(snapshots).to have_key([:recovery_provider_completed, 0])
      else
        expected_effects.times { |n| expect(snapshots).to have_key([:recovery_tools, n]) }
        expect(snapshots).to have_key([:recovery_tools_completed, expected_effects])
      end
      if composition.include?(:worker)
        expect(snapshots).to have_key(:child_reserved)
        expect(snapshots).to have_key(:child_terminal)
      end

      snapshots.each do |boundary, snapshot|
        recovered = reboot(snapshot)
        saved = recovered.executions.load(id)
        saved_slots = if (ref = saved.metadata["multi_agent_coordination_ref"])
          recovered.contents.fetch_json(ref).fetch("children")
        end
        remaining = (boundary == :child_terminal) ? ["parent result"] : followups
        llm = LLMStub.activate(responses: remaining)
        events = Queue.new
        loaded = parent_class.load(parent.agent_id, persistence: recovered,
          on_event: ->(event) { events << event.payload if event.type == :recovery_resolution_required })
        resolve_matrix_facts(loaded, events, outcome)
        expect(loaded.resume(id)[:output]).to eq(calls.empty? ? "resolved output" : "parent result"), boundary.inspect
        expect(llm.calls.size).to eq(calls.empty? ? 0 : remaining.size), boundary.inspect
        expect(effects).to eq(expected_effects), boundary.inspect
        if saved_slots
          final_slots = recovered.contents.fetch_json(recovered.executions.load(id).metadata.fetch("multi_agent_coordination_ref")).fetch("children")
          expect(final_slots.map { |slot| slot.fetch("execution_id") }).to eq(saved_slots.map { |slot| slot.fetch("execution_id") })
          final_slots.each { |slot| expect(recovered.list_executions(slot.fetch("agent_id")).size).to eq(1) }
        end
      end
    end
  end

  def resolve_matrix_facts(loaded, events, outcome)
    until events.empty?
      event = events.pop
      if event.fetch(:subject).fetch(:type) == :llm_call
        result = outcome.to_h
      else
        expect(event.fetch(:facts).fetch(:tool_name)).to eq("matrix_external")
        result = "external result"
      end
      loaded.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
        subject: event.fetch(:subject), outcome: :succeeded, result: result).wait_result(timeout: 3)
    end
  end

  [:coordinator, :worker].product([:child_terminal, :team_recorded]).each do |role, boundary|
    it "retains #{role} cancellation after restart at #{boundary}" do
      team = team_class.create(team_id: "cancel-boundary", persistence: store)
      filter = Class.new(Phronomy::Filter::Base) do
        define_method(:call) do |value, **_context|
          team.cancel(team.executions.first.team_execution_id)
          value
        end
      end
      if role == :worker
        worker.input_filter(filter)
      else
        allow(team).to receive(:coordinator_class).and_wrap_original do |original, id|
          original.call(id).tap { |klass| klass.input_filter(filter) }
        end
      end
      captured = nil
      child_id = nil
      store.after_commit = proc do |backend|
        run = backend.list_team_executions(team.team_id).first
        next unless run&.active? && !captured
        slot = (role == :worker) ? run.assignments.first : run.coordinator
        next unless slot
        child_id = slot.fetch("execution_id")
        begin
          child = backend.executions.load(child_id)
          recorded = slot.fetch("state") == "cancelled"
          if child.status == :cancelled && recorded == (boundary == :team_recorded)
            captured = backend.snapshot
          end
        rescue Phronomy::Persistence::NotFoundError
          nil
        end
      end
      LLMStub.activate(responses: team_responses)
      expect { team.invoke("plan") }.to raise_error(Phronomy::CancellationError)
      expect(captured).not_to be_nil
      restored = reboot(captured)
      loaded = team_class.load(team.team_id, persistence: restored)
      run = loaded.executions.first
      llm = LLMStub.activate(responses: ["must not replay"])
      expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::CancellationError)
      expect(loaded.executions.first.status).to eq("cancelled")
      expect(restored.executions.load(child_id).status).to eq(:cancelled)
      expect(llm.calls).to be_empty
    end
  end

  it "preserves skipped worker failures when cancellation is committed after their result" do
    team_class.pool(size: 1, agent: worker, on_error: :skip)
    worker.input_filter Class.new(Phronomy::Filter::Base) { define_method(:call) { |_value, **_context| raise "skipped worker failure" } }
    team = team_class.create(team_id: "skip-boundary", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      captured ||= backend.snapshot if run&.active? && run.assignments.any? { |entry| entry["state"] == "failed" }
    end
    LLMStub.activate(responses: team_responses)
    expect(team.invoke("plan").first.fetch("error").fetch("message")).to include("skipped worker failure")
    expect(captured).not_to be_nil
    [false, true].each do |cancel|
      restored = reboot(captured)
      loaded = team_class.load(team.team_id, persistence: restored)
      id = loaded.executions.first.team_execution_id
      loaded.cancel(id) if cancel
      llm = LLMStub.activate(responses: ["must not replay"])
      if cancel
        expect { loaded.resume(id) }.to raise_error(Phronomy::CancellationError)
        expect(loaded.executions.first.status).to eq("cancelled")
      else
        expect(loaded.resume(id).first.fetch("error").fetch("message")).to include("skipped worker failure")
        expect(loaded.executions.first.status).to eq("completed")
      end
      expect(loaded.executions.first.assignments.first.fetch("state")).to eq("failed")
      expect(llm.calls).to be_empty
    end
  end
  [:llm_call, :tool_invocation].product([:failed, :not_performed]).each do |subject_type, resolution_outcome|
    it "retains #{subject_type} #{resolution_outcome} across resolution commit and restart" do
      effects = 0
      external = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "failure_external"
        description "Application external effect"
        define_method(:execute) {
          effects += 1
          "external result"
        }
      end
      worker.tools(external => nil)
      original = worker.create(agent_id: "failure-resolution", persistence: store)
      captured = nil
      store.after_commit = proc do |backend|
        run = backend.list_executions(original.agent_id).first
        captured ||= backend.snapshot if run&.phase == :calling_llm
      end
      LLMStub.activate(responses: ["original result"])
      original.invoke("plan")
      expect(captured).not_to be_nil
      restored = reboot(captured)
      events = Queue.new
      llm = LLMStub.activate(responses: ["must not replay"])
      loaded = worker.load(original.agent_id, persistence: restored,
        on_event: ->(event) { events << event.payload if event.type == :recovery_resolution_required })
      event = Timeout.timeout(3) { events.pop }
      if subject_type == :tool_invocation
        outcome = Phronomy::Agent::ProviderCallOutcome.new(role: :assistant, content: nil,
          tool_calls: [{"id" => "failed-tool", "name" => "failure_external", "arguments" => {}}])
        loaded.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
          subject: event.fetch(:subject), outcome: :succeeded, result: outcome.to_h).wait_result(timeout: 3)
        event = Timeout.timeout(3) { events.pop }
      end
      expect(event.fetch(:subject).fetch(:type)).to eq(subject_type)
      after_resolution = nil
      restored.after_commit = proc do |backend|
        run = backend.executions.load(event.fetch(:execution_id))
        if !after_resolution && run.phase == :recovery_resolved_failed
          after_resolution = backend.snapshot
          raise IOError, "resolution commit response lost"
        end
      end
      material = (resolution_outcome == :failed) ? {error: RuntimeError.new("resolved failure")} : {}
      expected_message = (resolution_outcome == :failed) ? /resolved failure/ : /was not performed/
      expect do
        loaded.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
          subject: event.fetch(:subject), outcome: resolution_outcome, **material).wait_result(timeout: 3)
      end.to raise_error(Phronomy::Error, expected_message)
      expect(after_resolution).not_to be_nil
      expect(restored.executions.load(event.fetch(:execution_id)).status).to eq(:failed)
      expect(llm.calls).to be_empty
      recovered = reboot(after_resolution)
      llm = LLMStub.activate(responses: ["must not replay"])
      terminal = Queue.new
      recovered.after_commit = proc do |backend|
        run = backend.executions.load(event.fetch(:execution_id))
        terminal << run if run.terminal?
      end
      worker.load(original.agent_id, persistence: recovered)
      run = Timeout.timeout(3) { terminal.pop }
      expect(run.status).to eq(:failed)
      expect(recovered.contents.fetch_json(run.error_ref).fetch("message")).to match(expected_message)
      expect(llm.calls).to be_empty
      expect(effects).to eq(0)
    end
  end
end
