# frozen_string_literal: true

# Benchmark: typed ContextPolicyInput and split Context assembly.
#
# Usage:
#   ruby benchmark/bench_context_assembler.rb
#
# No provider call is performed.

require "benchmark"
require_relative "../lib/phronomy"

module BenchContextAssembler
  module_function

  def provenance
    Phronomy::Agent::ContextPolicyInput::Provenance.new(origin: :journal)
  end

  def policy_input(item_count)
    knowledge = []
    conversation = []
    item_count.times do |index|
      if (index % 10).zero?
        knowledge << Phronomy::Agent::ContextPolicyInput::KnowledgeItem.new(
          id: "knowledge-#{index}", kind: :knowledge, role: :user,
          content: "knowledge #{index}", content_format: :text,
          estimated_tokens: 8, required: false, provenance: provenance, metadata: {}
        )
      else
        conversation << [Phronomy::Agent::ContextPolicyInput::ConversationItem.new(
          id: "message-#{index}", kind: :external_message, role: :user,
          content: "message #{index}", content_format: :text,
          sequence: index, estimated_tokens: 8, required: false,
          provenance: provenance, tool_call_id: nil, tool_call_ids: [],
          delivery: :chat_message, metadata: {}
        )]
      end
    end

    Phronomy::Agent::ContextPolicyInput.new(
      agent_id: "bench-agent", execution_id: "bench-execution",
      call_sequence: 2, call_mode: :complete,
      instruction: [], knowledge: knowledge, tools: [], conversation: conversation,
      token_budget: Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: [item_count * 16, 4_096].max,
        max_output_tokens: 512
      ),
      model_config: {}, previous_manifest: nil, metadata: {}
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
    agent = agent_class.new(
      persistence: persistence,
      knowledge: ["Persistent benchmark knowledge"]
    )
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

puts "Typed Context Policy benchmark"
puts "Ruby #{RUBY_VERSION} on #{RUBY_PLATFORM}"
puts "=" * 72

policy = Phronomy::Agent::ContextPolicies::Default.instance
policy_inputs = [10, 100, 1_000].to_h do |count|
  [count, BenchContextAssembler.policy_input(count)]
end

Benchmark.bm(46) do |x|
  policy_inputs.each do |count, policy_input|
    iterations = (count >= 1_000) ? 200 : 1_000
    x.report("DefaultContextPolicy #{count} items x#{iterations}") do
      iterations.times { policy.call(policy_input) }
    end
  end

  assembler, root, execution = BenchContextAssembler.assembler_fixture
  x.report("ContextAssembler prepare/finalize x500") do
    500.times do
      prepared = assembler.prepare_initial(
        input: "benchmark input",
        agent_root: root,
        execution: execution
      )
      assembler.finalize(prepared)
    end
  end
end
