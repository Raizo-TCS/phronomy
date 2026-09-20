# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"
require_relative "phronomy/version"
require_relative "phronomy/llm_adapter/ruby_llm_patches"

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
# Context contracts keep their public Agent constants while living together.
loader.collapse("#{__dir__}/phronomy/agent/context_contract")

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
].each do |directory|
  loader.push_dir("#{__dir__}/phronomy/#{directory}", namespace: Phronomy)
end

# These files reopen existing namespaces or patch an external dependency.
loader.ignore(
  "#{__dir__}/phronomy/llm_adapter/ruby_llm_patches.rb",
  "#{__dir__}/phronomy/configuration/global_configuration.rb",
  "#{__dir__}/phronomy/runtime_composition/global_runtime.rb"
)
# Persistence conformance support must never make production loading require RSpec.
loader.ignore(
  "#{__dir__}/phronomy/testing/persistence_contract.rb",
  "#{__dir__}/phronomy/testing/persistence_contract"
)
loader.setup

require_relative "phronomy/llm_contract/token_usage"
require_relative "phronomy/configuration/global_configuration"
require_relative "phronomy/runtime_composition/global_runtime"

# Retain the Workflow recovery prepend during ordinary application loading.
# Agent lifecycle extensions remain installed when its namespace is loaded.
require_relative "phronomy/recovery/recovery"
require_relative "phronomy/workflow/execution/workflow_recovery"
