#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/api_snapshot.rb
#
# Dumps the public instance methods of all Stable/Beta public API classes to
# JSON.  The snapshot is stored in spec/fixtures/api_snapshot.json and is used
# by spec/phronomy/api_compatibility_spec.rb to detect unintended API removals.
#
# Usage:
#   # Regenerate spec/fixtures/api_snapshot.json (run when intentionally adding
#   # or removing public API methods after updating the stability table):
#   ruby scripts/api_snapshot.rb --write
#
#   # Print snapshot to stdout (useful for manual inspection):
#   ruby scripts/api_snapshot.rb

require "json"
require "fileutils"
require_relative "../lib/phronomy"

# Classes and modules whose public API is tracked.
# Add an entry whenever a new class/module is promoted to Stable or Beta in README.md.
PUBLIC_API_ENTRIES = [
  # Stable
  Phronomy::Agent::Base,
  Phronomy::Agent::Context::Capability::Base,
  Phronomy::Workflow,
  Phronomy::WorkflowContext,
  Phronomy::Runnable,
  Phronomy::Agent::Context::Instruction::PromptTemplate,
  # Beta
  Phronomy::Agent::ReactAgent,
  Phronomy::MultiAgent::Orchestrator,
  Phronomy::MultiAgent::TeamCoordinator,
  Phronomy::Guardrail::InputGuardrail,
  Phronomy::Guardrail::OutputGuardrail,
  Phronomy::RAG::VectorStore::Base,
  Phronomy::RAG::VectorStore::InMemory,
  Phronomy::RAG::Embeddings::Base,
  Phronomy::Agent::Context::Knowledge::Base,
  Phronomy::Agent::Context::Knowledge::StaticKnowledge,
  Phronomy::Tracing::Base,
  Phronomy::Tracing::NullTracer,
  Phronomy::Eval::Runner,
  Phronomy::Tools::Mcp,
  Phronomy::Tools::Agent
].freeze

# Baseline methods common to all Ruby objects — excluded from the snapshot.
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
    # Module — capture instance methods defined in this module only
    own_methods = klass.public_instance_methods(false).sort
    {
      "name" => klass.name,
      "type" => "module",
      "public_instance_methods" => own_methods
    }
  else
    # Class — capture public instance methods minus universal baseline
    instance_methods = (klass.public_instance_methods - BASELINE_INSTANCE_METHODS).sort
    class_methods = (klass.public_methods(false) - BASELINE_CLASS_METHODS).sort
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
