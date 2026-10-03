#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/api_snapshot.rb
#
# Dumps the public instance methods of all Stable/Beta product API classes to
# JSON. Testing helpers are intentionally excluded from this compatibility gate.
# The snapshot is stored in spec/fixtures/api_snapshot.json and is used by
# spec/phronomy/api_compatibility_spec.rb to detect unintended API removals.
#
# Usage:
#   ruby scripts/api_snapshot.rb --write
#   ruby scripts/api_snapshot.rb

require "json"
require "fileutils"
require_relative "../lib/phronomy"

PUBLIC_API_ENTRIES = [
  # Stable
  Phronomy::Agent::Base,
  Phronomy::Agent::ReservedExecution,
  Phronomy::Agent::ExecutionObservation,
  Phronomy::Agent::KnowledgeItem,
  Phronomy::Agent::Retention,
  Phronomy::Agent::ExecutionExtensionState,
  Phronomy::Agent::ControlRequest,
  Phronomy::Context::ContextPolicy,
  Phronomy::Context::ContextPolicyInput,
  Phronomy::Context::ContextPolicyInput::Provenance,
  Phronomy::Context::ContextPolicyInput::InstructionItem,
  Phronomy::Context::ContextPolicyInput::KnowledgeItem,
  Phronomy::Context::ContextPolicyInput::ToolItem,
  Phronomy::Context::ContextPolicyInput::ConversationItem,
  Phronomy::Context::ContextPlan,
  Phronomy::InvocationContext,
  Phronomy::Tool::Base,
  Phronomy::Workflow,
  Phronomy::WorkflowContext,
  Phronomy::Runnable,
  Phronomy::Context::PromptTemplate,
  # Beta
  Phronomy::MultiAgent::Handoff,
  Phronomy::MultiAgent::HandoffPolicy,
  Phronomy::MultiAgent::HandoffRunner,
  Phronomy::MultiAgent::Orchestrator,
  Phronomy::MultiAgent::TeamCoordinator,
  Phronomy::Filter::Base,
  Phronomy::Filter::PromptInjectionFilter,
  Phronomy::Storage::AsyncClient,
  Phronomy::VectorStore::Base,
  Phronomy::VectorStore::AsyncClient,
  Phronomy::VectorStore::InMemory,
  Phronomy::Embeddings::Base,
  Phronomy::Embeddings::AsyncClient,
  Phronomy::Tracing::Base,
  Phronomy::Tracing::NullTracer,
  Phronomy::Tools::Mcp,
  Phronomy::Tools::Agent,
  Phronomy::Tools::VectorSearch
].freeze

BASELINE_INSTANCE_METHODS = (
  Object.public_instance_methods |
  Kernel.public_instance_methods
).uniq.freeze

BASELINE_CLASS_METHODS = (
  Class.public_methods |
  Module.public_methods
).uniq.freeze

def snapshot_entry(klass)
  if klass.instance_of?(Module)
    own_methods = klass.public_instance_methods(false).sort
    {
      "name" => klass.name,
      "type" => "module",
      "public_instance_methods" => own_methods
    }
  else
    internal_context_methods = (klass == Phronomy::InvocationContext) ?
      %i[__bind_execution __execution_scope] : []
    instance_methods = (klass.public_instance_methods - BASELINE_INSTANCE_METHODS - internal_context_methods).sort
    internal_class_methods = (klass == Phronomy::Storage::AsyncClient) ? %i[submit] : []
    class_methods = (klass.public_methods(false) - BASELINE_CLASS_METHODS - internal_class_methods).sort
    {
      "name" => klass.name,
      "type" => "class",
      "public_instance_methods" => instance_methods,
      "public_class_methods" => class_methods
    }
  end
end

snapshot = PUBLIC_API_ENTRIES.map { |entry| snapshot_entry(entry) }

if ARGV.include?("--write")
  path = File.expand_path("../spec/fixtures/api_snapshot.json", __dir__)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.pretty_generate(snapshot) + "\n")
  puts "Wrote #{path}"
else
  puts JSON.pretty_generate(snapshot)
end
