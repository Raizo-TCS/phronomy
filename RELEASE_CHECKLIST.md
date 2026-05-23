# Release Checklist

Use this checklist before every release of the `phronomy` gem.
Copy it into the GitHub Release draft and check off each item.

---

## Pre-release

- [ ] `CHANGELOG.md` updated (Added / Changed / Fixed / Removed / Deprecated / Security)
- [ ] Version bumped in `lib/phronomy/version.rb`
- [ ] Stability table in `README.md` reflects any API additions, removals, or promotions
- [ ] `@api private` annotations are consistent with the README stability table (Issue #205)
- [ ] Public API compatibility snapshot regenerated if any Stable API changed:
  ```bash
  bundle exec ruby scripts/api_snapshot.rb --write
  ```
  (Issue #210)
- [ ] Migration notes or deprecation warnings added for any breaking changes

---

## Quality Gates (all must pass before tagging)

- [ ] `bundle exec rspec --format documentation` — 0 failures
- [ ] `bundle exec rspec --tag integration` — 0 failures, all expected pending
- [ ] `ruby scripts/check_japanese.rb` — exit 0 (no Japanese in source)
- [ ] `bundle exec standardrb` — 0 offenses
- [ ] `COVERAGE=1 bundle exec rspec` — coverage above configured threshold (Issue #207)
- [ ] CI green on all Ruby matrix versions (3.2 / 3.3 / 3.4 / head)

---

## Security Review

- [ ] `SECURITY.md` is up to date (supported versions table, contact info)
- [ ] No new `trace_pii`-sensitive data paths introduced without redaction
- [ ] No new `requires_approval` tools missing the approval gate
- [ ] No secrets, credentials, or PII in tool descriptions, schema strings, or spec fixtures
- [ ] Dependency audit passes: `bundle exec bundler-audit check --update`

---

## Release Steps

> **Do not use `gem push` directly.** The GitHub Actions release workflow handles
> gem publication. Follow the steps below exactly.

1. Commit the version bump:
   ```bash
   git commit -m "bump version to X.Y.Z"
   git push origin main
   ```
2. Create and push the tag:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
3. Trigger the release workflow:
   ```bash
   gh workflow run release.yml --field tag=vX.Y.Z
   ```
4. Monitor the workflow run:
   ```bash
   gh run list --workflow release.yml --limit 3
   ```
5. Verify the gem appears on RubyGems: `gem search phronomy`

---

## Post-release

- [ ] `phronomy-examples` `Gemfile` updated to the new version
  ```bash
  cd ../phronomy-examples && bundle update phronomy
  ```
- [ ] `phronomy-examples` tests pass after the update
- [ ] GitHub Release description includes the relevant CHANGELOG excerpt

---

## Reference Issues

- #205 — `@api private` annotation policy
- #207 — SimpleCov coverage gate
- #210 — Public API compatibility snapshot
