# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Task do
  subject(:task) do
    described_class.new(
      description:     "Do the research",
      agent_role:      :researcher,
      expected_output: "A list",
      context_from:    [:planner]
    )
  end

  it "exposes description, agent_role, expected_output, context_from" do
    expect(task.description).to eq("Do the research")
    expect(task.agent_role).to eq(:researcher)
    expect(task.expected_output).to eq("A list")
    expect(task.context_from).to eq([:planner])
  end

  it "defaults context_from to an empty array" do
    t = described_class.new(description: "x", agent_role: :a)
    expect(t.context_from).to eq([])
  end

  describe "#description_with_context" do
    it "returns the plain description when no previous_output in context" do
      expect(task.description_with_context({})).to eq("Do the research")
    end

    it "appends previous_output when present" do
      result = task.description_with_context(previous_output: "prior result")
      expect(result).to include("Do the research")
      expect(result).to include("prior result")
    end
  end
end

RSpec.describe Phronomy::Crew do
  def make_agent(output)
    agent = instance_double(Phronomy::Agent::Base)
    allow(agent).to receive(:invoke).and_return({output: output, messages: []})
    agent
  end

  let(:researcher) { make_agent("research result") }
  let(:writer)     { make_agent("written article") }

  let(:tasks) do
    [
      Phronomy::Task.new(description: "Research topic", agent_role: :researcher),
      Phronomy::Task.new(description: "Write article",  agent_role: :writer)
    ]
  end

  describe "#kickoff with :sequential process" do
    subject(:crew) do
      described_class.new(
        agents:  {researcher: researcher, writer: writer},
        tasks:   tasks,
        process: :sequential
      )
    end

    it "returns an array of results, one per task" do
      results = crew.kickoff
      expect(results.length).to eq(2)
    end

    it "returns the output from each agent" do
      results = crew.kickoff
      expect(results[0][:output]).to eq("research result")
      expect(results[1][:output]).to eq("written article")
    end

    it "passes previous output as context to the next task" do
      crew.kickoff
      expect(writer).to have_received(:invoke).with(a_string_including("research result"))
    end

    it "passes initial inputs as context to the first task" do
      crew.kickoff(topic: "Ruby")
      expect(researcher).to have_received(:invoke).with("Research topic")
    end

    it "raises ArgumentError when an agent role is missing" do
      crew_missing = described_class.new(
        agents: {researcher: researcher}, # no :writer
        tasks:  tasks
      )
      expect { crew_missing.kickoff }.to raise_error(ArgumentError, /writer/)
    end
  end

  describe "#kickoff with :hierarchical process" do
    let(:manager) { make_agent("managed output") }

    subject(:crew) do
      described_class.new(
        agents:  {manager: manager, researcher: researcher},
        tasks:   tasks,
        process: :hierarchical
      )
    end

    it "delegates to the :manager agent" do
      results = crew.kickoff(topic: "Ruby")
      expect(results.length).to eq(1)
      expect(manager).to have_received(:invoke)
    end

    it "raises ArgumentError when no :manager agent is present" do
      crew_no_manager = described_class.new(
        agents:  {researcher: researcher},
        tasks:   tasks,
        process: :hierarchical
      )
      expect { crew_no_manager.kickoff }.to raise_error(ArgumentError, /manager/)
    end
  end

  describe "#kickoff with unknown process" do
    it "raises ArgumentError" do
      crew = described_class.new(agents: {}, tasks: [], process: :unknown)
      expect { crew.kickoff }.to raise_error(ArgumentError, /unknown/i)
    end
  end
end
