# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 31: SharedState
#
# Pairwise factors:
#   ss_cycle_termination × ss_member_instruction × ss_coordination × ss_aggregate
#
# Generated test cases: 6 (all feasible)
#
# Infeasible cases: none
#
# LLM required: No (WebMock)
#   All LLM interactions are stubbed via LLMStub.  The researcher agent's
#   chat.ask calls are intercepted by WebMock so no real LM Studio connection
#   is required.
#
# LLM call sequence per cycle (1 researcher):
#   Call N  : tool_call write_finding({content: "finding_N"})
#   Call N+1: text response "OK" (LLM acknowledges tool result)

RSpec.describe "Group 31: SharedState", :integration do
  after { LLMStub.deactivate }

  # Shared researcher class (declared once; reused across all examples)
  let(:researcher_class) { IntegrationFactors.ss_researcher_class }

  # Two LLM responses per cycle: one tool_call, one text ack.
  # With max_cycles=2 we need 4 responses; for max_cycles=1 we need 2.
  # The LLMStub repeats the last response when the list is exhausted, so
  # supplying more than needed is harmless.
  def write_finding_response(content)
    LLMStub.tool_call_response("write_finding", {content: content})
  end

  # ---------------------------------------------------------------------------
  # TC-001: max_cycles / instruction=present / coordination=custom / aggregate=with_block
  #   The team runs for exactly 2 cycles (max_cycles).  The researcher has a
  #   per-agent instruction that must appear in every prompt sent to it.  A
  #   custom coordination text is set.  An aggregate block transforms the store
  #   into a joined string.
  # ---------------------------------------------------------------------------
  describe "TC-001: max_cycles / instruction=present / coordination=custom / aggregate=with_block" do
    let(:team_class) do
      IntegrationFactors.ss_team_class(
        termination: :max_cycles,
        instruction: :present,
        coordination: :custom,
        aggregate: :with_block,
        researcher: researcher_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        write_finding_response("finding_cycle1"),
        "OK",
        write_finding_response("finding_cycle2"),
        "OK"
      ])
    end

    it "terminates due to max_cycles" do
      result = team_class.new.invoke("Analyse the system")
      expect(result[:terminated_by]).to eq(:max_cycles)
    end

    it "completes exactly 2 cycles" do
      result = team_class.new.invoke("Analyse the system")
      expect(result[:cycles]).to eq(2)
    end

    it "returns a String output from the aggregate block" do
      result = team_class.new.invoke("Analyse the system")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).to include("finding_cycle1")
      expect(result[:output]).to include("finding_cycle2")
    end

    it "includes the per-agent instruction text in the researcher prompt" do
      team_class.new.invoke("Analyse the system")
      # Both cycles produce one tool call each; check prompt of first cycle call.
      first_messages = @llm.messages_for(0)
      user_turn = first_messages.find { |m| m["role"] == "user" }
      expect(user_turn["content"]).to include("Focus only on security aspects.")
    end

    it "includes the custom coordination text in the researcher prompt" do
      team_class.new.invoke("Analyse the system")
      first_messages = @llm.messages_for(0)
      user_turn = first_messages.find { |m| m["role"] == "user" }
      expect(user_turn["content"]).to include("CUSTOM COORDINATION GUIDE")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: max_cycles / instruction=absent / coordination=default / aggregate=none
  #   Runs 2 cycles with the default coordination guide and no per-agent
  #   instruction.  With no aggregate block the result[:output] is the raw
  #   Array of finding Hashes from the KnowledgeStore.
  # ---------------------------------------------------------------------------
  describe "TC-002: max_cycles / instruction=absent / coordination=default / aggregate=none" do
    let(:team_class) do
      IntegrationFactors.ss_team_class(
        termination: :max_cycles,
        instruction: :absent,
        coordination: :default,
        aggregate: :none,
        researcher: researcher_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        write_finding_response("finding_a"),
        "OK",
        write_finding_response("finding_b"),
        "OK"
      ])
    end

    it "terminates due to max_cycles" do
      result = team_class.new.invoke("Check the codebase")
      expect(result[:terminated_by]).to eq(:max_cycles)
    end

    it "returns raw findings Array when no aggregate block is set" do
      result = team_class.new.invoke("Check the codebase")
      expect(result[:output]).to be_an(Array)
      expect(result[:output].size).to eq(2)
    end

    it "does not include per-agent instruction text in the prompt" do
      team_class.new.invoke("Check the codebase")
      user_turn = @llm.messages_for(0).find { |m| m["role"] == "user" }
      expect(user_turn["content"]).not_to include("Focus only on security aspects.")
    end

    it "includes the default tool-usage guide in the prompt" do
      team_class.new.invoke("Check the codebase")
      user_turn = @llm.messages_for(0).find { |m| m["role"] == "user" }
      # Default guide references the write_finding tool by name.
      expect(user_turn["content"]).to match(/write_finding/i)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: terminate_when / instruction=present / coordination=default / aggregate=with_block
  #   A terminate_when block returns true after cycle 1 (store.size > 0).
  #   max_cycles is set to 100 so that termination is driven entirely by the
  #   block.  The researcher has a per-agent instruction.
  # ---------------------------------------------------------------------------
  describe "TC-003: terminate_when / instruction=present / coordination=default / aggregate=with_block" do
    let(:team_class) do
      IntegrationFactors.ss_team_class(
        termination: :terminate_when,
        instruction: :present,
        coordination: :default,
        aggregate: :with_block,
        researcher: researcher_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        write_finding_response("early_finding"),
        "OK"
      ])
    end

    it "terminates due to terminate_when" do
      result = team_class.new.invoke("Inspect the code")
      expect(result[:terminated_by]).to eq(:terminate_when)
    end

    it "stops after 1 cycle" do
      result = team_class.new.invoke("Inspect the code")
      expect(result[:cycles]).to eq(1)
    end

    it "returns a String output from the aggregate block" do
      result = team_class.new.invoke("Inspect the code")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).to include("early_finding")
    end

    it "includes the per-agent instruction in the first cycle prompt" do
      team_class.new.invoke("Inspect the code")
      user_turn = @llm.messages_for(0).find { |m| m["role"] == "user" }
      expect(user_turn["content"]).to include("Focus only on security aspects.")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: terminate_when / instruction=absent / coordination=custom / aggregate=none
  #   Same early-exit behaviour as TC-003 but with a custom coordination text
  #   and no per-agent instruction.  No aggregate block means raw Array output.
  # ---------------------------------------------------------------------------
  describe "TC-004: terminate_when / instruction=absent / coordination=custom / aggregate=none" do
    let(:team_class) do
      IntegrationFactors.ss_team_class(
        termination: :terminate_when,
        instruction: :absent,
        coordination: :custom,
        aggregate: :none,
        researcher: researcher_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        write_finding_response("finding_tc4"),
        "OK"
      ])
    end

    it "terminates due to terminate_when" do
      result = team_class.new.invoke("Scan the project")
      expect(result[:terminated_by]).to eq(:terminate_when)
    end

    it "returns a raw Array output" do
      result = team_class.new.invoke("Scan the project")
      expect(result[:output]).to be_an(Array)
    end

    it "includes the custom coordination text in the researcher prompt" do
      team_class.new.invoke("Scan the project")
      user_turn = @llm.messages_for(0).find { |m| m["role"] == "user" }
      expect(user_turn["content"]).to include("CUSTOM COORDINATION GUIDE")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: timeout / instruction=present / coordination=custom / aggregate=none
  #   timeout: 0 causes the deadline to expire immediately after cycle 1.
  #   max_cycles: 100 ensures only the timeout path is exercised.
  #   The per-agent instruction must appear in the prompt; no aggregate block.
  # ---------------------------------------------------------------------------
  describe "TC-005: timeout / instruction=present / coordination=custom / aggregate=none" do
    let(:team_class) do
      IntegrationFactors.ss_team_class(
        termination: :timeout,
        instruction: :present,
        coordination: :custom,
        aggregate: :none,
        researcher: researcher_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        write_finding_response("finding_tc5"),
        "OK"
      ])
    end

    it "terminates due to timeout" do
      result = team_class.new.invoke("Review the APIs")
      expect(result[:terminated_by]).to eq(:timeout)
    end

    it "completes at least 1 cycle before stopping" do
      result = team_class.new.invoke("Review the APIs")
      expect(result[:cycles]).to be >= 1
    end

    it "returns a raw Array output" do
      result = team_class.new.invoke("Review the APIs")
      expect(result[:output]).to be_an(Array)
    end

    it "includes the per-agent instruction in the researcher prompt" do
      team_class.new.invoke("Review the APIs")
      user_turn = @llm.messages_for(0).find { |m| m["role"] == "user" }
      expect(user_turn["content"]).to include("Focus only on security aspects.")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: timeout / instruction=absent / coordination=default / aggregate=with_block
  #   timeout: 0 terminates after cycle 1.  No per-agent instruction.
  #   An aggregate block should still be called with whatever findings exist.
  # ---------------------------------------------------------------------------
  describe "TC-006: timeout / instruction=absent / coordination=default / aggregate=with_block" do
    let(:team_class) do
      IntegrationFactors.ss_team_class(
        termination: :timeout,
        instruction: :absent,
        coordination: :default,
        aggregate: :with_block,
        researcher: researcher_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        write_finding_response("finding_tc6"),
        "OK"
      ])
    end

    it "terminates due to timeout" do
      result = team_class.new.invoke("Run the review")
      expect(result[:terminated_by]).to eq(:timeout)
    end

    it "returns a String output from the aggregate block" do
      result = team_class.new.invoke("Run the review")
      expect(result[:output]).to be_a(String)
    end

    it "includes the default coordination guide in the researcher prompt" do
      team_class.new.invoke("Run the review")
      user_turn = @llm.messages_for(0).find { |m| m["role"] == "user" }
      expect(user_turn["content"]).to match(/write_finding/i)
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern 5 requirement: Cross-agent information flow
  #
  # The shared-state pattern requires that later agents in a cycle immediately
  # see findings written by earlier agents in the same cycle (see
  # https://claude.com/blog/multi-agent-coordination-patterns, Pattern 5).
  #
  # Two distinct researcher classes are registered as members. Agent A runs
  # first in cycle 1 and writes a finding. Agent B runs second in the same
  # cycle; its LLM prompt must already contain Agent A's finding because
  # SharedState passes store.read_all into build_prompt when store.size > 0.
  # ---------------------------------------------------------------------------
  describe "Pattern 5 requirement: cross-agent information flow" do
    let(:researcher_a) { IntegrationFactors.ss_researcher_class }
    let(:researcher_b) { IntegrationFactors.ss_researcher_class }
    let(:team_class) do
      ra = researcher_a
      rb = researcher_b
      Class.new(Phronomy::Agent::SharedState) do
        max_cycles 1
        member ra
        member rb
      end
    end

    before do
      # Cycle 1 has two researchers. Agent A is call indices 0-1; Agent B is
      # call indices 2-3. Each does: tool_call(write_finding) → text "OK".
      @llm = LLMStub.activate(responses: [
        LLMStub.tool_call_response("write_finding", {content: "Finding from Agent A"}),
        "OK",
        LLMStub.tool_call_response("write_finding", {content: "Finding from Agent B"}),
        "OK"
      ])
    end

    it "Agent B's LLM prompt contains Agent A's finding from the same cycle" do
      team_class.new.invoke("Cross-agent visibility test")
      # LLM call index 2 is Agent B's first call within cycle 1.
      user_turn = @llm.messages_for(2).find { |m| m["role"] == "user" }
      expect(user_turn["content"]).to include("Finding from Agent A")
    end

    it "both agents write to the store (2 findings recorded)" do
      result = team_class.new.invoke("Cross-agent visibility test")
      expect(result[:output].size).to eq(2)
    end
  end
end
