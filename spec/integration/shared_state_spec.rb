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
      Class.new(Phronomy::MultiAgent::SharedState) do
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

RSpec.describe "SharedState default member configuration", :integration do
  after { LLMStub.deactivate }

  def default_team(member)
    Class.new(Phronomy::MultiAgent::SharedState) do
      member member
      max_cycles 1
    end
  end

  it "preserves an input filter that blocks the request before any LLM call" do
    member = IntegrationFactors.ss_researcher_class
    member.input_filter(IntegrationFactors::BlockingInputFilter.new)
    llm = LLMStub.activate(responses: ["This response must not be requested."])

    expect { default_team(member).new.invoke("Review") }
      .to raise_error(Phronomy::FilterBlockError, /input rejected/)
    expect(llm.calls).to be_empty
  end

  it "applies configured input, tool-result and output filters in the member invocation" do
    member = IntegrationFactors.ss_researcher_class
    seen = []
    member.input_filter(->(input) {
      seen << :input
      "Filtered request: #{input}"
    })
    member.tool_result_filter(->(value, **_context) {
      seen << :tool_result
      "Filtered result: #{value}"
    })
    member.output_filter(->(output) {
      seen << :output
      output
    })
    llm = LLMStub.activate(responses: [
      LLMStub.tool_call_response("write_finding", {content: "Reviewed finding"}),
      "Review complete."
    ])

    result = default_team(member).new.invoke("Review")

    expect(result.fetch(:output).map { |finding| finding.fetch(:content) }).to eq(["Reviewed finding"])
    expect(seen).to eq([:input, :tool_result, :output])
    first_input = llm.messages_for(0).find { |message| message["role"] == "user" }.fetch("content")
    expect(first_input).to start_with("Filtered request:")
    tool_result = llm.messages_for(1).find { |message| message["role"] == "tool" }.fetch("content")
    expect(tool_result).to eq("Filtered result: Finding recorded.")
  end

  %w[read_store write_finding].each do |reserved_name|
    it "rejects a member tool colliding with #{reserved_name} before any LLM call" do
      existing = Class.new(Phronomy::Tool::Base) do
        tool_name reserved_name
        description "An application tool with a conflicting sharing name"
        define_method(:execute) { "Application result" }
      end
      member = IntegrationFactors.ss_researcher_class
      member.tools(existing => nil)
      llm = LLMStub.activate(responses: ["This response must not be requested."])

      expect { default_team(member).new.invoke("Review") }
        .to raise_error(Phronomy::ConfigurationError, /duplicate effective Tool definition/)
      expect(llm.calls).to be_empty
      expect(member.tools).to eq([existing])
      expect(member.tool_aliases).to eq({})
    end
  end
end

RSpec.describe "SharedState application-owned records", :integration do
  after { LLMStub.deactivate }

  def record_tools(store)
    writer = Class.new(Phronomy::Tool::Base) do
      tool_name "record_issue"
      description "Publish a structured issue with an application category and severity"
      execution_mode :cooperative
      on_schema_error :raise
      param :category, type: :string, desc: "Issue category"
      param :severity, type: :integer, desc: "Severity from one to five"
      param :path, type: :string, desc: "Source file path"

      define_method(:execute) do |category:, severity:, path:|
        raise ArgumentError, "severity must be between one and five" unless (1..5).cover?(severity)

        store.fetch(:records) << {category: category, severity: severity, path: path}
        "recorded"
      end
    end
    reader = Class.new(Phronomy::Tool::Base) do
      tool_name "query_issues"
      description "Select issues using application-defined typed conditions"
      execution_mode :cooperative
      on_schema_error :raise
      param :minimum_severity, type: :integer, desc: "Minimum severity"
      param :category, type: :string, desc: "Category to include", required: false

      define_method(:execute) do |minimum_severity:, category: nil|
        store.fetch(:records).select do |record|
          record.fetch(:severity) >= minimum_severity && (!category || record.fetch(:category) == category)
        end.to_json
      end
    end
    {writer => "publish_issue", reader => "find_issues"}
  end

  def recording_provider(approval_required: false)
    owner = self
    @opened_stores = []
    @closed_stores = []
    @builder_calls = []
    stores = @opened_stores
    closed = @closed_stores
    builders = @builder_calls
    Object.new.tap do |provider|
      provider.define_singleton_method(:open) do |input:, config:, &block|
        store = {records: []}
        stores << store
        begin
          block.call(Phronomy::MultiAgent::SharedState::Binding.new(store: store,
            tools: ->(member:, cycle:) {
              builders << [member, cycle]
              owner.record_tools(store).tap do |definitions|
                definitions.keys.first.requires_approval(true) if approval_required
              end
            }))
        ensure
          closed << store
        end
      end
    end
  end

  def record_team(provider, *members)
    Class.new(Phronomy::MultiAgent::SharedState).tap do |team|
      team.sharing(provider, id: "integration-structured-records", version: 1)
      members.each { |member| team.member(member) }
      team.coordination("Publish issues and use find_issues to select relevant records.")
      team.max_cycles(1)
      team.aggregate { |store| store.fetch(:records).dup }
    end
  end

  it "shares structured records through typed tools without copying all records into member input" do
    first = IntegrationFactors.ss_researcher_class
    second = IntegrationFactors.ss_researcher_class
    provider = recording_provider
    llm = LLMStub.activate(responses: [
      LLMStub.tool_call_response("publish_issue", {category: "security", severity: 4, path: "login.rb"}),
      LLMStub.tool_call_response("publish_issue", {category: "performance", severity: 1, path: "cache.rb"}),
      "Published two issues.",
      LLMStub.tool_call_response("find_issues", {minimum_severity: 3, category: "security"}),
      "Reviewed the selected issue."
    ])

    result = record_team(provider, first, second).new.invoke("Review the repository")

    expect(result[:output]).to eq([
      {category: "security", severity: 4, path: "login.rb"},
      {category: "performance", severity: 1, path: "cache.rb"}
    ])
    expect(@builder_calls).to eq([[first, 1], [second, 1]])
    expect(@closed_stores).to eq(@opened_stores)
    expect(llm.calls.size).to eq(5)
    query_result = llm.messages_for(4).reverse.find { |message| message["role"] == "tool" }
    expect(JSON.parse(query_result.fetch("content"))).to eq([
      {"category" => "security", "severity" => 4, "path" => "login.rb"}
    ])
    second_input = llm.messages_for(3).find { |message| message["role"] == "user" }.fetch("content")
    expect(second_input).not_to include("login.rb", "cache.rb", "Findings so far")
    functions = llm.calls.fetch(3).fetch("tools").map { |tool| tool.fetch("function") }
    expect(functions.map { |function| function.fetch("name") }).to contain_exactly("publish_issue", "find_issues")
    query_schema = functions.find { |function| function["name"] == "find_issues" }.fetch("parameters")
    expect(query_schema.fetch("properties").fetch("minimum_severity").fetch("type")).to eq("integer")
  end

  it "rejects invalid typed input before changing the store and closes the provider" do
    provider = recording_provider
    LLMStub.activate(responses: [
      LLMStub.tool_call_response("publish_issue", {category: "security", severity: "urgent", path: "login.rb"})
    ])

    expect { record_team(provider, IntegrationFactors.ss_researcher_class).new.invoke("Review") }
      .to raise_error(Phronomy::ToolError)
    expect(@opened_stores.fetch(0).fetch(:records)).to eq([])
    expect(@closed_stores).to eq(@opened_stores)
  end

  it "preserves a member input filter that blocks the request before any LLM call" do
    member = IntegrationFactors.ss_researcher_class
    member.input_filter(IntegrationFactors::BlockingInputFilter.new)
    provider = recording_provider
    llm = LLMStub.activate(responses: ["This response must not be requested."])

    expect { record_team(provider, member).new.invoke("Review") }
      .to raise_error(Phronomy::FilterBlockError, /input rejected/)
    expect(llm.calls).to be_empty
    expect(@opened_stores.fetch(0).fetch(:records)).to eq([])
    expect(@closed_stores).to eq(@opened_stores)
  end

  it "keeps real approval waiting inside the provider scope and aggregates only after the reply" do
    requests = Queue.new
    agents = Queue.new
    aggregated = false
    member = IntegrationFactors.ss_researcher_class
    member.define_method(:initialize) do |**options|
      super(**options, on_event: ->(event) { requests << event.payload.fetch(:request) if event.type == :approval_required })
      agents << self
    end
    provider = recording_provider(approval_required: true)
    team = record_team(provider, member)
    team.aggregate do |store|
      aggregated = true
      store.fetch(:records).dup
    end
    llm = LLMStub.activate(responses: [
      LLMStub.tool_call_response("publish_issue", {category: "security", severity: 4, path: "login.rb"}),
      "Issue published after approval."
    ])
    coordinator = Thread.new do
      team.new.invoke("Review")
    rescue => error
      error
    end
    request = Timeout.timeout(5) { requests.pop }
    agent = agents.pop

    expect(agent.persistence.executions.load(request.execution_id).status).to eq(:suspended)
    expect(coordinator).to be_alive
    expect(@closed_stores).to eq([])
    expect(@opened_stores.fetch(0).fetch(:records)).to eq([])
    expect(aggregated).to be(false)
    agent.approve_async(request.execution_id, approval_request_id: request.id, approved: true).wait_result(timeout: 5)
    result = Timeout.timeout(5) { coordinator.value }

    expect(result).to include(output: [{category: "security", severity: 4, path: "login.rb"}])
    expect(aggregated).to be(true)
    expect(@closed_stores).to eq(@opened_stores)
    expect(llm.calls.size).to eq(2)
    expect { agent.invoke("Reuse the released member") }.to raise_error(Phronomy::AgentUnloadedError)
  ensure
    if coordinator&.alive?
      agent&.cancel_async(request.execution_id)&.wait_result(timeout: 5) if request
      coordinator.join(5)
      coordinator.kill if coordinator.alive?
    end
  end

  it "enforces typed conditions through the public Tool call contract" do
    store = {records: [{category: "security", severity: 4, path: "login.rb"}]}
    reader = record_tools(store).keys.last.new

    expect { reader.call({"minimum_severity" => "urgent"}) }
      .to raise_error(Phronomy::ToolError, /schema error/i)
    expect(store.fetch(:records)).to eq([{category: "security", severity: 4, path: "login.rb"}])
  end

  it "lets application validation reject a well-typed record before mutation" do
    store = {records: []}
    writer = record_tools(store).keys.first.new

    expect { writer.call({"category" => "security", "severity" => 99, "path" => "login.rb"}) }
      .to raise_error(Phronomy::ToolError, /severity/)
    expect(store.fetch(:records)).to eq([])
  end
end
