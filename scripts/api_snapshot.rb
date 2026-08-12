#!/usr/bin/env ruby
# frozen_string_literal: true

# scripts/api_snapshot.rb
#
# Dumps the public instance methods of all Stable/Beta public API classes to
# JSON. The snapshot is stored in spec/fixtures/api_snapshot.json and is used
# by spec/phronomy/api_compatibility_spec.rb to detect unintended API removals.
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
  Phronomy::Agent::Context::Capability::Base,
  Phronomy::Workflow,
  Phronomy::WorkflowContext,
  Phronomy::Runnable,
  Phronomy::Agent::Context::Instruction::PromptTemplate,
  # Beta
  Phronomy::MultiAgent::Orchestrator,
  Phronomy::MultiAgent::TeamCoordinator,
  Phronomy::Filter::Base,
  Phronomy::Filter::PromptInjectionFilter,
  Phronomy::VectorStore::Base,
  Phronomy::VectorStore::InMemory,
  Phronomy::VectorStore::Embeddings::Base,
  Phronomy::Tracing::Base,
  Phronomy::Tracing::NullTracer,
  Phronomy::Testing::Eval::Runner,
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
