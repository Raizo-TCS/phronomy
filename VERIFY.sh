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
  docs/decisions/021-generic-agent-invocation-identity-removal.md
  docs/decisions/022-agent-execution-parent-identity-and-runtime-routing-boundary.md
  docs/decisions/023-fsm-session-incarnation-identity-and-routing.md
  docs/decisions/024-event-loop-single-writer-agent-runtime.md
  docs/decisions/025-process-local-agent-ownership-and-runtime-admission.md
  docs/decisions/026-workflow-runtime-admission-and-durable-terminal-barrier.md
  lib/phronomy/workflow.rb
  lib/phronomy/workflow_context.rb
  lib/phronomy/workflow_runner.rb
  lib/phronomy/engine/event_loop.rb
  lib/phronomy/engine/fsm_session.rb
  lib/phronomy/persistence/in_memory.rb
  lib/phronomy/persistence/durable_record.rb
  lib/phronomy/persistence/durable_codec.rb
  lib/phronomy/persistence/repository_facades.rb
  lib/phronomy/persistence/migration/initial_format_migration.rb
  sig/phronomy/persistence.rbs
  spec/phronomy/persistence/backend_spi_api_spec.rb
  spec/phronomy/persistence/durable_codec_spec.rb
  spec/phronomy/persistence/in_memory_spec.rb
  spec/phronomy/persistence/initial_format_migration_spec.rb
  lib/phronomy/testing/persistence_contract/a_workflow_state_repository.rb
  spec/phronomy/workflow_identity_contract_spec.rb
  lib/phronomy/invocation_context.rb
  lib/phronomy/agent/async_event_api.rb
  lib/phronomy/agent/execution_coordinator.rb
  lib/phronomy/agent/journal_record.rb
  lib/phronomy/agent/context_assembler.rb
  lib/phronomy/agent/context_policy.rb
  lib/phronomy/agent/context_policy_input.rb
  lib/phronomy/agent/context_policy_input_builder.rb
  lib/phronomy/agent/context_plan.rb
  lib/phronomy/agent/context_plan_validator.rb
  lib/phronomy/agent/context_policies/default.rb
  spec/phronomy/agent/context_policy_architecture_regression_spec.rb
  lib/phronomy/agent/agent_invocation.rb
  lib/phronomy/multi_agent/orchestrator.rb
  lib/phronomy/multi_agent/fan_out_invocation.rb
  sig/phronomy/runtime.rbs
  spec/phronomy/generic_invocation_identity_contract_spec.rb
  spec/phronomy/agent/journal_record_llm_call_id_spec.rb
  spec/phronomy/agent/approval_parent_identity_contract_spec.rb
  spec/phronomy/fsm_session_identity_contract_spec.rb
  lib/phronomy/agent/tool_invocation.rb
  lib/phronomy/agent/tool_approval_request.rb
  lib/phronomy/agent/approval_evaluation_request.rb
  sig/phronomy/agent.rbs
  docs/persistence-backends.md
  spec/phronomy/invocation_context_spec.rb
  spec/phronomy/agent/async_event_contract_spec.rb
  spec/phronomy/workflow/admission_spec.rb
  spec/phronomy/workflow/live_signal_spec.rb
  spec/phronomy/workflow/transition_action_spec.rb
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
  lib/phronomy/agent_already_exists_error.rb
  lib/phronomy/agent_purged_error.rb
  lib/phronomy/engine/runtime/agent_ownership_registry.rb
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
  spec/phronomy/agent/event_loop_single_writer_spec.rb
  spec/phronomy/agent/tool_authorization_snapshot_boundary_spec.rb
  spec/phronomy/agent/same_process_ownership_spec.rb
  spec/phronomy/agent/runtime_admission_spec.rb
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
  lib/phronomy/engine/fsm_session.rb
  lib/phronomy/persistence/in_memory.rb
  lib/phronomy/persistence/durable_record.rb
  lib/phronomy/persistence/durable_codec.rb
  lib/phronomy/persistence/repository_facades.rb
  lib/phronomy/persistence/migration/initial_format_migration.rb
  spec/phronomy/persistence/backend_spi_api_spec.rb
  spec/phronomy/persistence/durable_codec_spec.rb
  spec/phronomy/persistence/in_memory_spec.rb
  spec/phronomy/persistence/initial_format_migration_spec.rb
  lib/phronomy/testing/persistence_contract/a_workflow_state_repository.rb
  spec/phronomy/workflow_identity_contract_spec.rb
  lib/phronomy/invocation_context.rb
  lib/phronomy/agent/async_event_api.rb
  lib/phronomy/agent/execution_coordinator.rb
  lib/phronomy/agent/journal_record.rb
  lib/phronomy/agent/context_assembler.rb
  lib/phronomy/agent/context_policy.rb
  lib/phronomy/agent/context_policy_input.rb
  lib/phronomy/agent/context_policy_input_builder.rb
  lib/phronomy/agent/context_plan.rb
  lib/phronomy/agent/context_plan_validator.rb
  lib/phronomy/agent/context_policies/default.rb
  spec/phronomy/agent/context_policy_architecture_regression_spec.rb
  lib/phronomy/agent/agent_invocation.rb
  lib/phronomy/multi_agent/orchestrator.rb
  lib/phronomy/multi_agent/fan_out_invocation.rb
  spec/phronomy/generic_invocation_identity_contract_spec.rb
  spec/phronomy/agent/journal_record_llm_call_id_spec.rb
  spec/phronomy/agent/approval_parent_identity_contract_spec.rb
  spec/phronomy/fsm_session_identity_contract_spec.rb
  lib/phronomy/agent/tool_invocation.rb
  lib/phronomy/agent/tool_approval_request.rb
  lib/phronomy/agent/approval_evaluation_request.rb
  spec/phronomy/invocation_context_spec.rb
  spec/phronomy/trace_context_task_tree_spec.rb
  spec/phronomy/agent/async_event_contract_spec.rb
  spec/phronomy/agent/persistence_logical_state_ownership_spec.rb
  spec/phronomy/agent/agent_invocation_spec.rb
  spec/phronomy/agent/agent_invocation_session_builder_spec.rb
  spec/phronomy/agent/tool_authorization_snapshot_boundary_spec.rb
  spec/phronomy/agent/same_process_ownership_spec.rb
  spec/phronomy/agent/runtime_admission_spec.rb
  spec/phronomy/concurrency/cancellation_token_spec.rb
  spec/phronomy/fault_injection_spec.rb
  spec/phronomy/multi_agent/team_coordinator_spec.rb
  spec/phronomy/multi_agent/orchestrator_knowledge_inheritance_spec.rb
  benchmark/bench_agent_invoke.rb
  benchmark/bench_regression.rb
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
  lib/phronomy/agent_already_exists_error.rb
  lib/phronomy/agent_purged_error.rb
  lib/phronomy/engine/runtime/agent_ownership_registry.rb
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

echo "== ACS-04 Context Policy four-category SPI =="
bundle exec rbs -I sig validate
bundle exec rspec \
  spec/phronomy/agent/context_policy_spec.rb \
  spec/phronomy/agent/context_policy_branch_coverage_spec.rb \
  spec/phronomy/agent/context_policy_architecture_regression_spec.rb \
  spec/phronomy/agent/knowledge_context_spec.rb \
  spec/phronomy/agent/manifest_token_budget_spec.rb \
  spec/phronomy/agent/stateful_followup_regression_spec.rb

echo "== CG-05 focused specs =="
bundle exec rspec \
  spec/phronomy/agent/context_policy_spec.rb \
  spec/phronomy/multi_agent/handoff_spec.rb \
  spec/phronomy/multi_agent/handoff_projection_spec.rb \
  spec/phronomy/multi_agent/handoff_architecture_regression_spec.rb \
  spec/phronomy/multi_agent/runner_spec.rb \
  spec/integration/multi_agent_handoff_spec.rb \
  spec/integration/multi_agent_handoff_followup_spec.rb

echo "== ACS-06 / CG-07 durable format / record-oriented Persistence SPI =="
ruby -c lib/phronomy/persistence.rb >/dev/null
ruby -c lib/phronomy/persistence/durable_record.rb >/dev/null
ruby -c lib/phronomy/persistence/durable_codec.rb >/dev/null
ruby -c lib/phronomy/persistence/repository_facades.rb >/dev/null
ruby -c lib/phronomy/persistence/in_memory.rb >/dev/null
ruby -c lib/phronomy/persistence/migration/initial_format_migration.rb >/dev/null
ruby -c spec/phronomy/persistence/backend_spi_api_spec.rb >/dev/null
ruby -c spec/phronomy/persistence/durable_codec_spec.rb >/dev/null
ruby -c spec/phronomy/persistence/in_memory_spec.rb >/dev/null
ruby -c spec/phronomy/persistence/initial_format_migration_spec.rb >/dev/null
bundle exec rbs -I sig validate
bundle exec rspec \
  spec/phronomy/persistence/backend_spi_api_spec.rb \
  spec/phronomy/persistence/durable_codec_spec.rb \
  spec/phronomy/persistence/in_memory_spec.rb \
  spec/phronomy/persistence/initial_format_migration_spec.rb \
  spec/phronomy/persistence/backend_contract_spec.rb \
  spec/phronomy/agent/agent_execution_codec_spec.rb \
  spec/phronomy/agent/llm_input_manifest_spec.rb \
  spec/phronomy/agent/approval_parent_identity_contract_spec.rb \
  spec/phronomy/persistence_architecture_regression_spec.rb

if grep -nE '\.payload([^[:alnum:]_]|$)' lib/phronomy/persistence/in_memory.rb; then
  echo "FAIL: raw InMemory Backend reintroduced DurableRecord payload interpretation" >&2
  exit 1
fi

echo "== CG-02 generic invocation identity / durable Journal compatibility =="
bundle exec rbs -I sig validate
bundle exec rspec   spec/phronomy/generic_invocation_identity_contract_spec.rb   spec/phronomy/agent/journal_record_llm_call_id_spec.rb   spec/phronomy/agent/agent_execution_codec_spec.rb   spec/phronomy/invocation_context_spec.rb   spec/phronomy/trace_context_task_tree_spec.rb   spec/phronomy/agent/base_spec.rb   spec/phronomy/agent_spec.rb   spec/phronomy/agent/async_event_contract_spec.rb   spec/phronomy/agent/before_llm_input_spec.rb   spec/phronomy/agent/persistence_logical_state_ownership_spec.rb   spec/phronomy/agent/agent_invocation_spec.rb   spec/phronomy/agent/agent_invocation_session_builder_spec.rb   spec/phronomy/concurrency/cancellation_token_spec.rb   spec/phronomy/fault_injection_spec.rb   spec/phronomy/multi_agent/orchestrator_spec.rb   spec/phronomy/multi_agent/team_coordinator_spec.rb   spec/phronomy/multi_agent/orchestrator_knowledge_inheritance_spec.rb   spec/integration/orchestrator_spec.rb   spec/phronomy/api_compatibility_spec.rb

legacy_correlation_source="$(
  grep -RInE '(^|[^[:alnum:]_])correlation_id:' lib/phronomy     --include='*.rb' || true
)"
if [[ -n "$legacy_correlation_source" ]]; then
  echo "FAIL: active source still writes generic correlation_id:" >&2
  printf '%s\n' "$legacy_correlation_source" >&2
  exit 1
fi

echo "== ACS-11 EventLoop single-writer Agent runtime =="
ruby -c lib/phronomy/agent/execution_coordinator.rb >/dev/null
ruby -c lib/phronomy/agent/agent_invocation.rb >/dev/null
ruby -c lib/phronomy/agent/agent_invocation_session_builder.rb >/dev/null
ruby -c lib/phronomy/agent/phase_machine_builder.rb >/dev/null
ruby -c lib/phronomy/agent/tool_invocation.rb >/dev/null
ruby -c lib/phronomy/agent/approval_evaluation_request.rb >/dev/null
ruby -c lib/phronomy/engine/event_loop.rb >/dev/null
ruby -c spec/phronomy/agent/event_loop_single_writer_spec.rb >/dev/null
ruby -c spec/phronomy/agent/tool_authorization_snapshot_boundary_spec.rb >/dev/null
bundle exec rbs -I sig validate
bundle exec rspec   spec/phronomy/agent/event_loop_single_writer_spec.rb   spec/phronomy/agent/tool_authorization_snapshot_boundary_spec.rb   spec/phronomy/agent/tool_invocation_spec.rb   spec/phronomy/agent/approval_parent_identity_contract_spec.rb   spec/phronomy/api_compatibility_spec.rb   spec/phronomy/agent/approve_async_spec.rb   spec/phronomy/agent/canonical_execution_log_spec.rb   spec/phronomy/agent/persistence_logical_state_ownership_spec.rb   spec/phronomy/persistence_architecture_regression_spec.rb   spec/phronomy/fsm_session_identity_contract_spec.rb

if grep -RInE 'AgentExecutionActivation|ActivationRegistry|__agent_activations|phronomy_activation'     lib/phronomy --include='*.rb'; then
  echo "FAIL: ACS-11 removed Activation model remains in active production source" >&2
  exit 1
fi

echo "== ACS-12 process-local Agent ownership / Runtime admission =="
ruby -c lib/phronomy/engine/runtime/agent_ownership_registry.rb >/dev/null
ruby -c lib/phronomy/agent/base.rb >/dev/null
ruby -c lib/phronomy/agent/execution_coordinator.rb >/dev/null
ruby -c lib/phronomy/engine/event_loop.rb >/dev/null
ruby -c spec/phronomy/agent/same_process_ownership_spec.rb >/dev/null
ruby -c spec/phronomy/agent/runtime_admission_spec.rb >/dev/null
bundle exec rbs -I sig validate
bundle exec rspec \
  spec/phronomy/agent/same_process_ownership_spec.rb \
  spec/phronomy/agent/runtime_admission_spec.rb \
  spec/phronomy/agent/persistence_logical_state_ownership_spec.rb \
  spec/phronomy/agent/base_spec.rb \
  spec/phronomy/api_compatibility_spec.rb \
  spec/phronomy/persistence_architecture_regression_spec.rb

echo "== CG-03b / ACS-10 FSMSession routing foundation =="
bundle exec rspec \
  spec/phronomy/fsm_session_identity_contract_spec.rb \
  spec/phronomy/workflow/fsm_session_spec.rb \
  spec/phronomy/workflow/transition_action_spec.rb \
  spec/phronomy/workflow/live_signal_spec.rb \
  spec/phronomy/workflow_identity_contract_spec.rb \
  spec/phronomy/persistence_architecture_regression_spec.rb \
  spec/phronomy/lifecycle_invariants_spec.rb \
  spec/phronomy/event_loop_queue_observability_spec.rb \
  spec/phronomy/architecture_regression_spec.rb \
  spec/phronomy/generic_invocation_identity_contract_spec.rb \
  spec/phronomy/agent/agent_invocation_spec.rb \
  spec/phronomy/agent/agent_invocation_session_builder_spec.rb \
  spec/phronomy/agent/tool_invocation_session_builder_spec.rb \
  spec/phronomy/agent/tool_invocation_spec.rb \
  spec/phronomy/agent/tool_call_async_compatibility_spec.rb \
  spec/phronomy/agent/approval_parent_identity_contract_spec.rb \
  spec/phronomy/agent/suspend_resume_spec.rb \
  spec/phronomy/multi_agent/orchestrator_spec.rb

if grep -RIn 'parent_agent_invocation_id\|parent_fsm_session_id' \
    lib/phronomy --include='*.rb'; then
  echo "FAIL: long-lived Agent/Tool parent Runtime routing field remains" >&2
  exit 1
fi

legacy_runtime_identity="$(
  grep -RInE 'graph_thread_id|payload: [{]session_id:' \
    lib/phronomy --include='*.rb' || true
)"
if [[ -n "$legacy_runtime_identity" ]]; then
  echo "FAIL: active Runtime source still contains legacy generic routing bridge:" >&2
  printf '%s\n' "$legacy_runtime_identity" >&2
  exit 1
fi

python3 - <<'PY'
import pathlib, re

def fsm_new_has_id_kwarg(text):
    """Return True only if FSMSession.new(...) itself has an id: keyword argument."""
    pos = 0
    while True:
        m = re.search(r'FSMSession\.new\(', text[pos:])
        if not m:
            return False
        start = pos + m.end()
        depth = 1
        i = start
        while i < len(text) and depth > 0:
            if text[i] == '(':
                depth += 1
            elif text[i] == ')':
                depth -= 1
            i += 1
        call_args = text[start:i - 1]
        if re.search(r'\bid\s*:', call_args):
            return True
        pos = pos + m.end()
    return False

for rel in [
    "lib/phronomy/agent/agent_invocation_session_builder.rb",
    "lib/phronomy/agent/tool_invocation_session_builder.rb",
    "lib/phronomy/multi_agent/fan_out_session_builder.rb",
]:
    text = pathlib.Path(rel).read_text()
    if fsm_new_has_id_kwarg(text):
        raise SystemExit(f"FAIL: {rel} still injects a domain/context ID as FSMSession id")

workflow = pathlib.Path("lib/phronomy/workflow_runner.rb").read_text()
event_loop = pathlib.Path("lib/phronomy/engine/event_loop.rb").read_text()
fsm = pathlib.Path("lib/phronomy/engine/fsm_session.rb").read_text()

if "Phronomy::FSMSession.reserve_identity" in workflow:
    raise SystemExit("FAIL: ACS-13 Workflow still pre-reserves FSMSession identity for admission")
if "owner_fsm_session_id" in workflow or "owner_fsm_session_id" in event_loop:
    raise SystemExit("FAIL: ACS-13 Workflow admission still conflates owner and routing identity")
for required in ["owner_token: Object.new.freeze", "bind_workflow_session"]:
    if required not in workflow:
        raise SystemExit(f"FAIL: WorkflowRunner missing ACS-13 invariant: {required}")
for required in ["WorkflowAdmission = Data.define", ":owner_token, :fsm_session_id, :state"]:
    if required not in event_loop:
        raise SystemExit(f"FAIL: EventLoop missing ACS-13 admission invariant: {required}")
for required in ["workflow_terminal_persistence_result", ":persisting_terminal", ":recovery_required"]:
    if required not in fsm:
        raise SystemExit(f"FAIL: FSMSession missing ACS-13 terminal barrier invariant: {required}")
PY

echo "== ACS-13 Workflow admission / durable terminal barrier =="
ruby -c lib/phronomy/workflow_runner.rb >/dev/null
ruby -c lib/phronomy/engine/event_loop.rb >/dev/null
ruby -c lib/phronomy/engine/fsm_session.rb >/dev/null
ruby -c spec/phronomy/workflow/admission_spec.rb >/dev/null
ruby -c spec/phronomy/workflow/transition_action_spec.rb >/dev/null
ruby -c spec/phronomy/fsm_session_identity_contract_spec.rb >/dev/null
bundle exec rspec \
  spec/phronomy/workflow/admission_spec.rb \
  spec/phronomy/workflow/live_signal_spec.rb \
  spec/phronomy/workflow/transition_action_spec.rb \
  spec/phronomy/fsm_session_identity_contract_spec.rb \
  spec/phronomy/persistence_architecture_regression_spec.rb \
  spec/integration/wait_state_spec.rb \
  spec/integration/graph_spec.rb

echo "== CG-03a Agent execution parent identity =="
bundle exec rbs -I sig validate
bundle exec rspec \
  spec/phronomy/agent/approval_parent_identity_contract_spec.rb \
  spec/phronomy/agent/tool_invocation_spec.rb \
  spec/phronomy/agent/tool_call_async_compatibility_spec.rb \
  spec/phronomy/agent/agent_invocation_spec.rb \
  spec/phronomy/agent/agent_invocation_session_builder_spec.rb \
  spec/phronomy/agent/suspend_resume_spec.rb \
  spec/integration/approval_resume_spec.rb \
  spec/phronomy/agent/agent_execution_codec_spec.rb \
  spec/phronomy/api_compatibility_spec.rb

legacy_approval_public="$(
  grep -RInE 'agent_invocation_id'     lib/phronomy/agent/tool_approval_request.rb     lib/phronomy/agent/approval_evaluation_request.rb     sig/phronomy/agent.rbs || true
)"
if [[ -n "$legacy_approval_public" ]]; then
  echo "FAIL: public approval contract still contains agent_invocation_id:" >&2
  printf '%s\n' "$legacy_approval_public" >&2
  exit 1
fi

legacy_agent_invocation_identity="$(
  grep -RInE '(^|[^[:alnum:]_])agent_invocation_id([^[:alnum:]_]|$)'     lib/phronomy sig/phronomy --include='*.rb' --include='*.rbs' || true
)"
legacy_agent_invocation_identity="$(
  printf '%s\n' "$legacy_agent_invocation_identity" |
    grep -v 'lib/phronomy/agent/base.rb' |
    grep -v 'lib/phronomy/agent/agent_execution.rb' |
    grep -v 'lib/phronomy/persistence/migration/initial_format_migration.rb' || true
)"
if [[ -n "$legacy_agent_invocation_identity" ]]; then
  echo "FAIL: active source/RBS reintroduced agent_invocation_id domain identity:" >&2
  printf '%s\n' "$legacy_agent_invocation_identity" >&2
  exit 1
fi

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

echo "OK: ACS-13 + ACS-12 + CG-03b routing foundation + CG-03a + CG-02 + CG-01 + ACS-06 + ACS-05 + ACS-03 + ACS-07 + ACS-18 + ACS-01 + existing CG-04/CG-05 regression validation completed"
