# Contributing to phronomy

Thank you for your interest in contributing!

---

## Development Setup

```bash
git clone https://github.com/Raizo-TCS/phronomy.git
cd phronomy
bundle install
```

Run the test suite:

```bash
bundle exec rspec --format documentation
bundle exec rspec --tag integration
```

Run the linter:

```bash
bundle exec standardrb
```

Check that no Japanese characters appear in source files:

```bash
ruby scripts/check_japanese.rb
```

---

## Code Style

- All source files under `lib/` and `spec/` must begin with `# frozen_string_literal: true`.
- All comments, error messages (`raise`), and YARD documentation inside source files must be in **English**.
- Follow [Ruby Standard Style](https://github.com/standardrb/standard) (`standardrb`).

---

## Public API Changes

When adding, removing, or renaming a public method or class:

1. Update the stability table in `README.md`.
2. Add or update `@api private` YARD annotations for internal APIs.
3. Regenerate the API compatibility snapshot:
   ```bash
   bundle exec ruby scripts/api_snapshot.rb --write
   ```

---

## Architecture Decision Records

Key design decisions are documented as ADRs in
[docs/decisions/](docs/decisions/). Read these before making significant changes
to the threading model, caching strategy, or public API shape.

---

## Releasing

See [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) for the full pre-release quality
gate and step-by-step release instructions.

**Never run `gem push` directly.** Releases are published via the GitHub Actions
`release.yml` workflow.
