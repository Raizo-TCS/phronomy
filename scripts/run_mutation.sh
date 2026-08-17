#!/usr/bin/env bash
# scripts/run_mutation.sh — Run mutation tests on core Phronomy domain classes.
#
# Usage:
#   bash scripts/run_mutation.sh [SUBJECT_PATTERN]
#
# SUBJECT_PATTERN (optional): restrict to a specific subject, e.g. "Phronomy::WorkflowContext"
# When omitted, all subjects listed in .mutant.yml are tested.
#
# Requires mutant-rspec (in Gemfile development group):
#   gem "mutant-rspec", "~> 0.15.1"
#
# Target: mutation score >= 80% for each listed subject.
# Baseline scores (as of initial run):
#   Phronomy::WorkflowContext  84.85%
#   Phronomy::Agent::Context::Capability::Base  55.74%
#     (public facade alias: Phronomy::Tool::Base; same Class object)
#
# Note: mutation testing is slow (~1-5 min per subject). Run locally or via
# the nightly-mutation GitHub Actions workflow.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! bundle exec mutant --version &>/dev/null; then
  echo "ERROR: mutant is not available. Run: bundle install"
  exit 1
fi

SUBJECT="${1:-}"

echo "=== Phronomy Mutation Test ==="
echo "Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Ruby: $(ruby --version)"
echo "Mutant: $(bundle exec mutant --version 2>&1 | grep -v warning | head -1)"
echo ""

if [[ -n "$SUBJECT" ]]; then
  echo "Subject: $SUBJECT"
  echo ""
  bundle exec mutant run -- "$SUBJECT"
else
  echo "Subjects: all (see .mutant.yml)"
  echo ""
  bundle exec mutant run
fi
