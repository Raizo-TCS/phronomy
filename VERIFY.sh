#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

if [[ -e phronomy-0.16.0.gem ]]; then
  echo "FAIL: remove phronomy-0.16.0.gem before validation" >&2
  exit 1
fi

required_files=(
  lib/phronomy/multi_agent/coordinator.rb
  spec/phronomy/multi_agent/handoff_spec.rb
  spec/phronomy/multi_agent/handoff_projection_spec.rb
  spec/phronomy/multi_agent/handoff_architecture_regression_spec.rb
  spec/integration/multi_agent_handoff_spec.rb
  spec/integration/multi_agent_handoff_followup_spec.rb
  docs/migrations/0.22.md
  docs/decisions/016-semantic-multi-agent-handoff.md
)
for path in "${required_files[@]}"; do
  [[ -f "$path" ]] || { echo "FAIL: missing $path" >&2; exit 1; }
done

for path in \
  lib/phronomy/agent/context_assembler.rb \
  lib/phronomy/agent/context_parts/requirements/required_context_resolver.rb \
  lib/phronomy/agent/selection/unit_builders/dependency_aware_unit_builder.rb \
  lib/phronomy/multi_agent/coordinator.rb \
  spec/phronomy/agent/context_policy_spec.rb \
  spec/phronomy/multi_agent/handoff_spec.rb \
  spec/phronomy/multi_agent/handoff_projection_spec.rb \
  spec/phronomy/multi_agent/handoff_architecture_regression_spec.rb \
  spec/integration/multi_agent_handoff_spec.rb \
  spec/integration/multi_agent_handoff_followup_spec.rb; do
  ruby -c "$path" >/dev/null
done

echo "== CG-05 focused specs =="
bundle exec rspec \
  spec/phronomy/agent/context_policy_spec.rb \
  spec/phronomy/multi_agent/handoff_spec.rb \
  spec/phronomy/multi_agent/handoff_projection_spec.rb \
  spec/phronomy/multi_agent/handoff_architecture_regression_spec.rb \
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
rm -rf tmp/cg05-gem-unpack
mkdir -p tmp/cg05-gem-unpack
built_gem=$(gem build phronomy.gemspec | awk '/File: / {print $2}' | tail -n 1)
if [[ -z "${built_gem:-}" || ! -f "$built_gem" ]]; then
  echo "FAIL: gem build did not produce a package" >&2
  exit 1
fi
gem unpack "$built_gem" --target tmp/cg05-gem-unpack >/dev/null
if find tmp/cg05-gem-unpack -type f -name '*.gem' -print -quit | grep -q .; then
  echo "FAIL: built gem contains a nested .gem artifact" >&2
  exit 1
fi

echo "OK: CG-05 focused/full validation completed"
