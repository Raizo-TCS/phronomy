# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"
require_relative "phronomy/version"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect("ruby_llm_embeddings" => "RubyLLMEmbeddings")
loader.inflector.inflect("rag" => "RAG")
loader.inflector.inflect("fsm_session" => "FSMSession")
loader.inflector.inflect("fsm_protocol" => "FSMProtocol")
loader.inflector.inflect("llm_adapter" => "LLMAdapter")
loader.inflector.inflect("llm_operation_result" => "LLMOperationResult")
loader.inflector.inflect("ruby_llm" => "RubyLLM")
loader.inflector.inflect("canonical_json" => "CanonicalJSON")
loader.inflector.inflect("ruby_llm_materializer" => "RubyLLMMaterializer")
loader.inflector.inflect("llm_call_record" => "LLMCallRecord")
loader.inflector.inflect("llm_input_manifest" => "LLMInputManifest")
loader.inflector.inflect("llm_input_build_context" => "LLMInputBuildContext")
loader.inflector.inflect("llm_input_patch" => "LLMInputPatch")
loader.inflector.inflect("before_llm_input" => "BeforeLLMInput")
# These responsibility directories do not add a public Ruby namespace.
%w[common configuration engine generation llm_contract recovery].each do |directory|
  loader.collapse("#{__dir__}/phronomy/#{directory}")
end
# LLM contracts, execution clients and implementations have separate source
# directories, while keeping their existing feature namespace.
%w[llm_adapter/async llm_adapter/backends].each do |directory|
  loader.collapse("#{__dir__}/phronomy/#{directory}")
end
# Agent responsibility directories retain the existing Agent constant names.
%w[
  context_contract lifecycle execution tool_execution context_assembly
  journal handoff recovery
].each do |directory|
  loader.collapse("#{__dir__}/phronomy/agent/#{directory}")
end

# A nested root is independent of its enclosing Ruby namespace. Keep existing
# Phronomy::Workflow, Phronomy::WorkflowContext, and other canonical constants
# beside the feature they belong to, without aliases or a new partial-load API.
%w[
  agent/api
  agent/lifecycle_contract
  filter/contract
  output_parser/contract
  persistence/api
  tool/contract
  workflow/execution
  workflow/storage_contract
  multi_agent/storage_contract
].each do |directory|
  loader.push_dir("#{__dir__}/phronomy/#{directory}", namespace: Phronomy)
end

# These files wire composition, reopen namespaces, or patch a dependency.
loader.ignore(
  "#{__dir__}/phronomy/configuration/global_configuration.rb",
  "#{__dir__}/phronomy/agent/composition",
  "#{__dir__}/phronomy/runtime_composition/agent_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/configuration_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/global_runtime.rb"
)
# Persistence conformance support must never make production loading require RSpec.
loader.ignore(
  "#{__dir__}/phronomy/testing/persistence_contract.rb",
  "#{__dir__}/phronomy/testing/persistence_contract"
)
loader.setup

require_relative "phronomy/runtime_composition/configuration_defaults"
require_relative "phronomy/llm_contract/token_usage"
require_relative "phronomy/configuration/global_configuration"
require_relative "phronomy/runtime_composition/global_runtime"

# Explicitly install the Agent namespace extensions even if its factory
# contract was loaded first. Composition owns both concrete binding and the
# run_once method definition; neither is required from Agent execution files.
require_relative "phronomy/agent/api/agent"
require_relative "phronomy/runtime_composition/agent_defaults"
require_relative "phronomy/agent/composition/run_once"

# Load the common recovery vocabulary during ordinary application loading.
require_relative "phronomy/recovery/recovery"
