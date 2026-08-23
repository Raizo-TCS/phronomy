#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

if [[ -e phronomy-0.16.0.gem ]]; then
  echo "FAIL: remove phronomy-0.16.0.gem before validation" >&2
  exit 1
fi

required_files=(
  docs/decisions/README.md
  docs/decisions/017-design-authority-and-adr-governance.md
  docs/decisions/018-durability-guarantees-and-failure-model.md
  docs/decisions/019-filter-contract-and-security-boundaries.md
  docs/decisions/020-canonical-workflow-instance-identity.md
  lib/phronomy/workflow.rb
  lib/phronomy/workflow_context.rb
  lib/phronomy/workflow_runner.rb
  lib/phronomy/engine/event_loop.rb
  lib/phronomy/persistence/in_memory.rb
  lib/phronomy/testing/persistence_contract/a_workflow_state_repository.rb
  spec/phronomy/workflow_identity_contract_spec.rb
  spec/phronomy/workflow/admission_spec.rb
  spec/phronomy/workflow/live_signal_spec.rb
  lib/phronomy/generator_verifier.rb
  spec/phronomy/generator_verifier_spec.rb
  spec/integration/subgraph_parallel_agent_tool_spec.rb
  lib/phronomy/tracing/base.rb
  lib/phronomy/tracing/langfuse_tracer.rb
  spec/phronomy/tracing/extension_contract_spec.rb
  spec/phronomy/tracing/open_telemetry_tracer_spec.rb
  spec/phronomy/tracing/langfuse_tracer_spec.rb
  spec/integration/tracing_adapters_spec.rb
  spec/phronomy/architecture_governance_spec.rb
  spec/phronomy/filter_architecture_regression_spec.rb
  spec/phronomy/filter_blocking_spec.rb
  spec/integration/tool_filter_spec.rb
  spec/phronomy/guarantee_model_spec.rb
  spec/phronomy/before_llm_input_rbs_contract_spec.rb
  spec/phronomy/fault_injection_spec.rb
  spec/phronomy/fault_injection_advanced_spec.rb
  spec/phronomy/persistence_architecture_regression_spec.rb
  lib/phronomy/agent/base.rb
  lib/phronomy/agent/agent_root.rb
  lib/phronomy/agent/llm_input_build_context.rb
  lib/phronomy/agent/shared_state.rb
  spec/phronomy/agent/base_spec.rb
  spec/phronomy/agent_spec.rb
  spec/phronomy/agent/before_llm_input_spec.rb
  spec/phronomy/agent/agent_execution_codec_spec.rb
  spec/phronomy/agent/shared_state_spec.rb
  docs/migrations/0.22.md
  docs/features.md
  lib/phronomy/multi_agent/coordinator.rb
  spec/phronomy/multi_agent/handoff_spec.rb
  spec/phronomy/multi_agent/handoff_projection_spec.rb
  spec/phronomy/multi_agent/handoff_architecture_regression_spec.rb
  spec/phronomy/multi_agent/runner_spec.rb
  spec/integration/multi_agent_handoff_spec.rb
  spec/integration/multi_agent_handoff_followup_spec.rb
  docs/decisions/016-semantic-multi-agent-handoff.md
)
for path in "${required_files[@]}"; do
  [[ -f "$path" ]] || { echo "FAIL: missing $path" >&2; exit 1; }
done

syntax_files=(
  spec/phronomy/architecture_governance_spec.rb
  lib/phronomy/workflow.rb
  lib/phronomy/workflow_context.rb
  lib/phronomy/workflow_runner.rb
  lib/phronomy/engine/event_loop.rb
  lib/phronomy/persistence/in_memory.rb
  lib/phronomy/testing/persistence_contract/a_workflow_state_repository.rb
  spec/phronomy/workflow_identity_contract_spec.rb
  spec/phronomy/workflow_spec.rb
  spec/phronomy/workflow_context_spec.rb
  spec/phronomy/workflow/admission_spec.rb
  spec/phronomy/workflow/live_signal_spec.rb
  spec/phronomy/workflow/fsm_session_spec.rb
  lib/phronomy/generator_verifier.rb
  spec/phronomy/generator_verifier_spec.rb
  spec/integration/subgraph_parallel_agent_tool_spec.rb
  spec/phronomy/guarantee_model_spec.rb
  spec/phronomy/before_llm_input_rbs_contract_spec.rb
  lib/phronomy/tracing/base.rb
  lib/phronomy/tracing/langfuse_tracer.rb
  spec/phronomy/tracing/extension_contract_spec.rb
  spec/phronomy/tracing/langfuse_tracer_spec.rb
  spec/phronomy/filter_architecture_regression_spec.rb
  spec/phronomy/filter_blocking_spec.rb
  spec/phronomy/security_spec.rb
  spec/phronomy/fault_injection_extended_spec.rb
  spec/integration/tool_filter_spec.rb
  spec/integration/support/factors.rb
  spec/integration/streaming_spec.rb
  spec/phronomy/fault_injection_spec.rb
  spec/phronomy/fault_injection_advanced_spec.rb
  spec/phronomy/persistence_architecture_regression_spec.rb
  lib/phronomy/agent/base.rb
  lib/phronomy/agent/agent_root.rb
  lib/phronomy/agent/llm_input_build_context.rb
  lib/phronomy/agent/shared_state.rb
  lib/phronomy/agent/concerns/before_llm_input.rb
  lib/phronomy/testing/persistence_contract/an_agent_repository.rb
  lib/phronomy/testing/persistence_contract/an_execution_repository.rb
  lib/phronomy/testing/persistence_contract/a_journal_repository.rb
  lib/phronomy/testing/persistence_contract/a_persistence_backend.rb
  spec/phronomy/agent/base_spec.rb
  spec/phronomy/agent_spec.rb
  spec/phronomy/agent/before_llm_input_spec.rb
  spec/phronomy/agent/agent_execution_codec_spec.rb
  spec/phronomy/agent/shared_state_spec.rb
  spec/phronomy/agent/journal_projection_spec.rb
  spec/phronomy/agent/stateful_followup_regression_spec.rb
  spec/phronomy/persistence/in_memory_spec.rb
  lib/phronomy/agent/context_assembler.rb
  lib/phronomy/agent/context_parts/requirements/required_context_resolver.rb
  lib/phronomy/agent/selection/unit_builders/dependency_aware_unit_builder.rb
  lib/phronomy/multi_agent/coordinator.rb
  spec/phronomy/agent/context_policy_spec.rb
  spec/phronomy/multi_agent/handoff_spec.rb
  spec/phronomy/multi_agent/handoff_projection_spec.rb
  spec/phronomy/multi_agent/handoff_architecture_regression_spec.rb
  spec/phronomy/multi_agent/runner_spec.rb
  spec/integration/multi_agent_handoff_spec.rb
  spec/integration/multi_agent_handoff_followup_spec.rb
)
for path in "${syntax_files[@]}"; do
  ruby -c "$path" >/dev/null
done

echo "== ACS-01 architecture governance =="
bundle exec rspec spec/phronomy/architecture_governance_spec.rb

echo "== ACS-03 Filter authority / terminology cleanup =="
bundle exec rspec \
  spec/phronomy/filter_architecture_regression_spec.rb \
  spec/phronomy/filter_spec.rb \
  spec/phronomy/filter_blocking_spec.rb \
  spec/phronomy/prompt_injection_defenses_spec.rb \
  spec/phronomy/security_spec.rb \
  spec/phronomy/fault_injection_extended_spec.rb \
  spec/phronomy/fault_injection_advanced_spec.rb \
  spec/integration/tool_filter_spec.rb

echo "== ACS-05 Tracing extension contract / coverage cleanup =="
bundle exec rspec \
  spec/phronomy/tracing/extension_contract_spec.rb \
  spec/phronomy/tracing/base_spec.rb \
  spec/phronomy/tracing_spec.rb \
  spec/phronomy/tracing/open_telemetry_tracer_spec.rb \
  spec/phronomy/tracing/langfuse_tracer_spec.rb \
  spec/integration/tracing_adapters_spec.rb

echo "== ACS-18 guarantee / failure taxonomy =="
bundle exec rspec \
  spec/phronomy/guarantee_model_spec.rb \
  spec/phronomy/fault_injection_spec.rb \
  spec/phronomy/fault_injection_advanced_spec.rb \
  spec/phronomy/persistence_architecture_regression_spec.rb

echo "== ACS-07 before_llm_input Stable typed contract =="
bundle exec rbs -I sig validate
bundle exec rspec \
  spec/phronomy/before_llm_input_rbs_contract_spec.rb \
  spec/phronomy/agent/before_llm_input_spec.rb \
  spec/phronomy/public_api_spec.rb

echo "== CG-04 canonical vocabulary guards =="
legacy_source="$(
  grep -RInE '\bdefinition_version\b' lib/phronomy sig/phronomy \
    --include='*.rb' --include='*.rbs' || true
)"
if [[ -n "$legacy_source" ]]; then
  echo "FAIL: active source/RBS still contains legacy definition_version:" >&2
  printf '%s\n' "$legacy_source" >&2
  exit 1
fi

legacy_usage="$(
  grep -RInE '\.definition_version\b|(^|[^[:alnum:]_])definition_version:' \
    lib/phronomy sig/phronomy spec \
    --include='*.rb' --include='*.rbs' || true
)"
if [[ -n "$legacy_usage" ]]; then
  echo "FAIL: executable code/spec still uses legacy definition_version accessor/keyword:" >&2
  printf '%s\n' "$legacy_usage" >&2
  exit 1
fi

echo "== CG-04 focused specs =="
bundle exec rspec \
  spec/phronomy/agent/base_spec.rb \
  spec/phronomy/agent_spec.rb \
  spec/phronomy/agent/before_llm_input_spec.rb \
  spec/phronomy/agent/agent_execution_codec_spec.rb \
  spec/phronomy/agent/shared_state_spec.rb \
  spec/phronomy/agent/journal_projection_spec.rb \
  spec/phronomy/agent/stateful_followup_regression_spec.rb \
  spec/phronomy/persistence/in_memory_spec.rb \
  spec/phronomy/persistence/backend_contract_spec.rb

echo "== CG-05 focused specs =="
bundle exec rspec \
  spec/phronomy/agent/context_policy_spec.rb \
  spec/phronomy/multi_agent/handoff_spec.rb \
  spec/phronomy/multi_agent/handoff_projection_spec.rb \
  spec/phronomy/multi_agent/handoff_architecture_regression_spec.rb \
  spec/phronomy/multi_agent/runner_spec.rb \
  spec/integration/multi_agent_handoff_spec.rb \
  spec/integration/multi_agent_handoff_followup_spec.rb

echo "== CG-01 Workflow identity =="
bundle exec rbs -I sig validate
bundle exec rspec \
  spec/phronomy/workflow_identity_contract_spec.rb \
  spec/phronomy/workflow_spec.rb \
  spec/phronomy/workflow_context_spec.rb \
  spec/phronomy/workflow/admission_spec.rb \
  spec/phronomy/workflow/live_signal_spec.rb \
  spec/phronomy/workflow/fsm_session_spec.rb \
  spec/phronomy/generator_verifier_spec.rb \
  spec/integration/subgraph_parallel_agent_tool_spec.rb \
  spec/phronomy/persistence/backend_contract_spec.rb \
  spec/phronomy/persistence_architecture_regression_spec.rb \
  spec/integration/wait_state_spec.rb \
  spec/integration/graph_spec.rb

echo "== API snapshot =="
bundle exec ruby scripts/api_snapshot.rb

echo "== RBS =="
bundle exec rbs -I sig validate

echo "== API annotations =="
ruby scripts/check_api_annotations.rb

echo "== Default test task =="
bundle exec rake

echo "== All stub-based integration specs =="
bundle exec rspec --tag integration --format progress

echo "== Gem package guard =="
rm -rf tmp/cg04-cg05-gem-unpack
mkdir -p tmp/cg04-cg05-gem-unpack
built_gem=$(gem build phronomy.gemspec | awk '/File: / {print $2}' | tail -n 1)
if [[ -z "${built_gem:-}" || ! -f "$built_gem" ]]; then
  echo "FAIL: gem build did not produce a package" >&2
  exit 1
fi
gem unpack "$built_gem" --target tmp/cg04-cg05-gem-unpack >/dev/null
if find tmp/cg04-cg05-gem-unpack -type f -name '*.gem' -print -quit | grep -q .; then
  echo "FAIL: built gem contains a nested .gem artifact" >&2
  exit 1
fi

echo "OK: CG-01 + ACS-05 + ACS-03 + ACS-07 + ACS-18 + ACS-01 + existing CG-04/CG-05 regression validation completed"
