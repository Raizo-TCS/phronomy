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
loader.inflector.inflect("llm_call_record" => "LLMCallRecord")
loader.inflector.inflect("llm_input_manifest" => "LLMInputManifest")
loader.inflector.inflect("llm_input_build_context" => "LLMInputBuildContext")
loader.inflector.inflect("llm_input_patch" => "LLMInputPatch")
loader.inflector.inflect("before_llm_input" => "BeforeLLMInput")
# These responsibility directories do not add a public Ruby namespace.
%w[common configuration engine execution generation runtime_composition].each do |directory|
  loader.collapse("#{__dir__}/phronomy/#{directory}")
end
# Backend contracts, execution clients and implementations have separate source
# directories, while keeping their existing feature namespace.
%w[
  llm_adapter/async llm_adapter/backends
  vector_store/async vector_store/backends
  embeddings/async embeddings/backends
  storage/async
  multi_agent/runtime_binding
].each do |directory|
  loader.collapse("#{__dir__}/phronomy/#{directory}")
end
# Agent responsibility directories retain the existing Agent constant names.
%w[
  lifecycle execution tool_execution runtime_binding
  journal handoff recovery
].each do |directory|
  loader.collapse("#{__dir__}/phronomy/agent/#{directory}")
end

# A nested root is independent of its enclosing Ruby namespace. Keep existing
# Phronomy::Workflow, Phronomy::WorkflowContext, and other canonical constants
# beside the feature they belong to, without aliases or a new partial-load API.
%w[
  agent/api
  workflow/execution
  workflow/runtime_binding
].each do |directory|
  loader.push_dir("#{__dir__}/phronomy/#{directory}", namespace: Phronomy)
end

# These files wire composition, reopen namespaces, or patch a dependency.
loader.ignore(
  "#{__dir__}/phronomy/persistence/persistence.rb",
  "#{__dir__}/phronomy/persistence/errors.rb",
  "#{__dir__}/phronomy/persistence_composition/stores.rb",
  "#{__dir__}/phronomy/runtime_composition/global_configuration.rb",
  "#{__dir__}/phronomy/agent/composition",
  "#{__dir__}/phronomy/runtime_composition/agent_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/generation_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/evaluation_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/workflow_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/multi_agent_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/configuration_defaults.rb",
  "#{__dir__}/phronomy/runtime_composition/global_runtime.rb",
  "#{__dir__}/phronomy/runtime_composition/execution_defaults.rb"
)
# Optional application integrations are loaded explicitly by their consumers.
loader.ignore("#{__dir__}/phronomy/integrations")
# Persistence conformance support must never make production loading require RSpec.
loader.ignore(
  "#{__dir__}/phronomy/testing/persistence_contract.rb",
  "#{__dir__}/phronomy/testing/persistence_contract"
)
# Failure contracts can define Persistence before ordinary framework loading.
# Explicitly install its service methods without constructing a backend/Runtime.
require_relative "phronomy/persistence/persistence"
require_relative "phronomy/persistence/errors"
loader.ignore("#{__dir__}/phronomy/tool/tool_error.rb")
loader.ignore("#{__dir__}/phronomy/filter/filter_block_error.rb")
loader.ignore("#{__dir__}/phronomy/output_parser/parse_error.rb")
loader.ignore("#{__dir__}/phronomy/agent/agent_busy_error.rb")
loader.ignore("#{__dir__}/phronomy/agent/agent_purged_error.rb")
loader.ignore("#{__dir__}/phronomy/agent/stream_callback_error.rb")
loader.ignore("#{__dir__}/phronomy/agent/handoff_error.rb")
loader.ignore("#{__dir__}/phronomy/agent/agent_already_exists_error.rb")
loader.setup
require_relative "phronomy/persistence/transaction"
require_relative "phronomy/persistence_composition/stores"
require_relative "phronomy/tool/tool_error"
require_relative "phronomy/filter/filter_block_error"
require_relative "phronomy/output_parser/parse_error"
require_relative "phronomy/agent/agent_busy_error"
require_relative "phronomy/agent/agent_purged_error"
require_relative "phronomy/agent/stream_callback_error"
require_relative "phronomy/agent/handoff_error"
require_relative "phronomy/agent/agent_already_exists_error"

require_relative "phronomy/runtime_composition/configuration_defaults"
require_relative "phronomy/llm_adapter/token_usage"
require_relative "phronomy/runtime_composition/global_configuration"
require_relative "phronomy/runtime_composition/global_runtime"
require_relative "phronomy/runtime_composition/execution_defaults"

# Explicitly install the Agent namespace extensions even if its factory
# contract was loaded first. Composition owns both concrete binding and the
# run_once method definition; neither is required from Agent execution files.
require_relative "phronomy/agent/api/agent"
require_relative "phronomy/runtime_composition/agent_defaults"
require_relative "phronomy/runtime_composition/multi_agent_defaults"
require_relative "phronomy/runtime_composition/workflow_defaults"
require_relative "phronomy/runtime_composition/generation_defaults"
require_relative "phronomy/runtime_composition/evaluation_defaults"
require_relative "phronomy/agent/composition/run_once"

# Preserve ordinary boot loading of the existing recovery rules and comparisons
# while giving each definition its owning domain.
require_relative "phronomy/agent/recovery/recovery_rules"
require_relative "phronomy/persistence/snapshot_comparison"
