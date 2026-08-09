# frozen_string_literal: true

# Benchmark: Manifest-first Context assembly and Default Context Policy.
#
# Usage:
#   ruby benchmark/bench_context_assembler.rb
#
# This replaces the legacy Phronomy::LlmContextWindow::Assembler benchmark.
# It intentionally measures both:
#   1. ContextPolicies::Default selection cost for growing candidate sets.
#   2. ContextAssembler#build_initial end-to-end Manifest construction.
#
# No provider call is performed.

require "benchmark"
require_relative "../lib/phronomy"

module BenchContextAssembler
  module_function

  def candidate(index)
    Phronomy::Agent::ContextCandidate.new(
      candidate_id: "candidate-#{index}",
      source_kind: :journal,
      category: :llm_message,
      role: index.even? ? :assistant : :user,
      content_ref: "content-#{index}",
      record_id: "record-#{index}",
      agent_id: "bench-agent",
      execution_id: "execution-#{index / 4}",
      llm_call_id: nil,
      tool_call_id: nil,
      sequence: index,
      requirement: :optional,
      priority: 0,
      metadata: {
        "estimated_tokens" => 8,
        "source_sequence" => index
      }
    )
  end

  def parts
    {
      unit_builder:
        Phronomy::Agent::ContextParts::UnitBuilders::DependencyAwareUnitBuilder.new,
      required_context_resolver:
        Phronomy::Agent::ContextParts::Requirements::RequiredContextResolver.new,
      recent_first_selector:
        Phronomy::Agent::ContextParts::Selectors::RecentFirstSelector.new,
      token_budget_packer:
        Phronomy::Agent::ContextParts::Budget::TokenBudgetPacker.new
    }.freeze
  end

  def request(candidate_count)
    candidates = Array.new(candidate_count) { |i| candidate(i) }
    Phronomy::Agent::ContextRequest.new(
      agent_id: "bench-agent",
      execution_id: "bench-execution",
      call_sequence: 2,
      call_mode: :complete,
      candidates: candidates,
      token_budget: Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: [candidate_count * 16, 4_096].max,
        max_output_tokens: 512
      ),
      model_config: {},
      previous_manifest: nil,
      required_coverage: [],
      parts: parts,
      metadata: {"mandatory_token_estimate" => 32}
    )
  end

  def assembler_fixture
    persistence = Phronomy::Persistence::InMemory.new
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "bench-manifest-context-assembler", version: 1
      model "local-model"
      context_window 16_384
      max_output_tokens 1_024
      instructions "Benchmark instruction"
    end
    agent = agent_class.new(persistence: persistence)
    root = agent.agent_root
    input_ref = persistence.contents.put_text("benchmark input")
    input_record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id,
      kind: :external_message,
      channel: :external,
      role: :user,
      content_ref: input_ref,
      context_generation: root.transcript_generation,
      context_candidate: true
    )
    execution = Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: input_record,
      metadata: {
        "current_input_ref" => input_ref,
        "current_input_record_id" => input_record.record_id
      }
    ).with(
      execution_revision: 0,
      working_records: [input_record]
    )

    [
      Phronomy::Agent::ContextAssembler.new(agent: agent, persistence: persistence),
      root,
      execution
    ]
  end
end

puts "Manifest-first Context benchmark"
puts "Ruby #{RUBY_VERSION} on #{RUBY_PLATFORM}"
puts "=" * 72

policy = Phronomy::Agent::ContextPolicies::Default.new
policy_requests = [10, 100, 1_000].to_h do |count|
  [count, BenchContextAssembler.request(count)]
end

Benchmark.bm(46) do |x|
  policy_requests.each do |count, request|
    iterations = (count >= 1_000) ? 200 : 1_000
    x.report("DefaultContextPolicy #{count} candidates x#{iterations}") do
      iterations.times { policy.call(request) }
    end
  end

  assembler, root, execution = BenchContextAssembler.assembler_fixture
  x.report("ContextAssembler#build_initial x500") do
    500.times do
      assembler.build_initial(
        input: "benchmark input",
        agent_root: root,
        execution: execution
      )
    end
  end
end
