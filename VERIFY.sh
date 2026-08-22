#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

if [[ -e phronomy-0.16.0.gem ]]; then
  echo "FAIL: remove phronomy-0.16.0.gem before validation" >&2
  exit 1
fi

required_files=(
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

echo "OK: CG-04 + existing CG-05 validation completed"
