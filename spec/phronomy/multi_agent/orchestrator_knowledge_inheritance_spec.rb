# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Orchestrator Knowledge inheritance" do
  def knowledge_capturing_agent
    received = []
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "orchestrator-knowledge-capture", version: 1

      define_method(:invoke) do |input, thread_id: nil, config: {}, invocation_context: nil, on_event: nil|
        knowledge = journal_projection.context_records.filter_map do |record|
          next unless record.kind == :knowledge

          {
            content: persistence.contents.fetch_text(record.content_ref),
            metadata: record.metadata
          }
        end
        received << {input: input, knowledge: knowledge}
        {output: "ok", messages: []}
      end

      define_method(:invoke_async) do |input, thread_id: nil, config: {}, invocation_context: nil, on_tool_approval_required: nil, on_event: nil|
        Phronomy::Task.spawn(name: "knowledge-capture") do
          invoke(
            input,
            thread_id: thread_id,
            config: config,
            invocation_context: invocation_context,
            on_event: on_event
          )
        end
      end
    end

    [agent_class, received]
  end

  def build_orchestrator(klass = Class.new(Phronomy::MultiAgent::Orchestrator))
    agent = klass.new
    agent.add_knowledge(
      "Customer tier: enterprise",
      metadata: {"origin" => "customer_profile"}
    )
    agent
  end

  let(:expected_knowledge) do
    [
      {
        content: "Customer tier: enterprise",
        metadata: {"origin" => "customer_profile"}
      }
    ]
  end

  describe "#subagent" do
    it "inherits active parent Knowledge by default, including metadata" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator

      orchestrator.subagent(child_class, "task")

      expect(received).to eq(
        [{input: "task", knowledge: expected_knowledge}]
      )
    end

    it "supports explicit Knowledge isolation" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator

      orchestrator.subagent(
        child_class,
        "isolated task",
        inherit_knowledge: false
      )

      expect(received).to eq(
        [{input: "isolated task", knowledge: []}]
      )
    end

    it "does not read parent Knowledge when inheritance is disabled" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator
      expect(orchestrator).not_to receive(:active_knowledge_snapshot)

      orchestrator.subagent(
        child_class,
        "isolated task",
        inherit_knowledge: false
      )

      expect(received).to eq(
        [{input: "isolated task", knowledge: []}]
      )
    end

    it "inherits only currently active Knowledge" do
      child_class, received = knowledge_capturing_agent
      orchestrator = Class.new(Phronomy::MultiAgent::Orchestrator).new(
        knowledge: ["obsolete knowledge"]
      )
      orchestrator.clear_knowledge!
      orchestrator.add_knowledge("current knowledge")

      orchestrator.subagent(child_class, "task")

      expect(received.first[:knowledge].map { |entry| entry[:content] })
        .to eq(["current knowledge"])
    end
  end

  describe "#dispatch_parallel" do
    it "inherits Knowledge by default and allows a task-level opt-out" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator

      orchestrator.dispatch_parallel(
        {agent: child_class, input: "shared"},
        {
          agent: child_class,
          input: "isolated",
          inherit_knowledge: false
        }
      )

      by_input = received.to_h { |entry| [entry[:input], entry[:knowledge]] }
      expect(by_input.fetch("shared")).to eq(expected_knowledge)
      expect(by_input.fetch("isolated")).to eq([])
    end

    it "supports a call-wide Knowledge opt-out without reading parent Knowledge" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator
      expect(orchestrator).not_to receive(:active_knowledge_snapshot)

      orchestrator.dispatch_parallel(
        {agent: child_class, input: "a"},
        {agent: child_class, input: "b"},
        inherit_knowledge: false
      )

      expect(received.map { |entry| entry[:knowledge] })
        .to all(eq([]))
    end

    it "does not read parent Knowledge when every task opts out" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator
      expect(orchestrator).not_to receive(:active_knowledge_snapshot)

      orchestrator.dispatch_parallel(
        {agent: child_class, input: "a", inherit_knowledge: false},
        {agent: child_class, input: "b", inherit_knowledge: false}
      )

      expect(received.map { |entry| entry[:knowledge] })
        .to all(eq([]))
    end

    it "captures one snapshot when a task opts in against a call-wide opt-out" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator
      expect(orchestrator).to receive(:active_knowledge_snapshot).once.and_call_original

      orchestrator.dispatch_parallel(
        {agent: child_class, input: "isolated"},
        {agent: child_class, input: "shared", inherit_knowledge: true},
        inherit_knowledge: false
      )

      by_input = received.to_h { |entry| [entry[:input], entry[:knowledge]] }
      expect(by_input.fetch("isolated")).to eq([])
      expect(by_input.fetch("shared")).to eq(expected_knowledge)
    end
  end

  describe "#fan_out" do
    it "inherits parent Knowledge for every generated subagent" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator

      orchestrator.fan_out(
        agent: child_class,
        inputs: %w[a b]
      )

      expect(received.length).to eq(2)
      expect(received.map { |entry| entry[:knowledge] })
        .to all(eq(expected_knowledge))
    end

    it "does not read parent Knowledge when inheritance is disabled" do
      child_class, received = knowledge_capturing_agent
      orchestrator = build_orchestrator
      expect(orchestrator).not_to receive(:active_knowledge_snapshot)

      orchestrator.fan_out(
        agent: child_class,
        inputs: %w[a b],
        inherit_knowledge: false
      )

      expect(received.map { |entry| entry[:knowledge] })
        .to all(eq([]))
    end
  end

  describe ".subagent DSL" do
    it "inherits parent Knowledge through the prepared dispatch tool" do
      child_class, received = knowledge_capturing_agent
      orchestrator_class = Class.new(Phronomy::MultiAgent::Orchestrator) do
        subagent :worker, child_class
      end
      orchestrator = build_orchestrator(orchestrator_class)
      tool_class = orchestrator_class.tools.first
      prepared_tool = orchestrator.send(:prepare_tool_class, tool_class)

      result = prepared_tool.new.call({input: "dsl task"})

      expect(result).to eq("ok")
      expect(received).to eq(
        [{input: "dsl task", knowledge: expected_knowledge}]
      )
    end

    it "supports disabling Knowledge inheritance for a declared subagent" do
      child_class, received = knowledge_capturing_agent
      orchestrator_class = Class.new(Phronomy::MultiAgent::Orchestrator) do
        subagent :worker, child_class, inherit_knowledge: false
      end
      orchestrator = build_orchestrator(orchestrator_class)
      tool_class = orchestrator_class.tools.first
      expect(orchestrator).not_to receive(:active_knowledge_snapshot)
      prepared_tool = orchestrator.send(:prepare_tool_class, tool_class)

      prepared_tool.new.call({input: "dsl isolated"})

      expect(received).to eq(
        [{input: "dsl isolated", knowledge: []}]
      )
    end

    it "stores the Knowledge inheritance policy in registered_subagents" do
      child_class, = knowledge_capturing_agent
      orchestrator_class = Class.new(Phronomy::MultiAgent::Orchestrator) do
        subagent :inheriting, child_class
        subagent :isolated, child_class, inherit_knowledge: false
      end

      expect(orchestrator_class.registered_subagents.fetch(:inheriting))
        .to include(inherit_knowledge: true)
      expect(orchestrator_class.registered_subagents.fetch(:isolated))
        .to include(inherit_knowledge: false)
    end
  end
end
