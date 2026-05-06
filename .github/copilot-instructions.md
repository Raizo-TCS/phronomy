# CRITICAL (STRICTLY ENFORCED)
# "Do not report back without taking action on already-agreed items. Only report when you have achieved the requested objective, or when there is something that genuinely requires confirmation."
# - Do not post "re-confirmation" updates for already-agreed items.
# - Reports must be limited to either "objective completed" or "items that genuinely require confirmation".

# Project Rules and Instructions

## Language Policy
**All chat communications must be in Japanese.**
- Always respond to the user in Japanese
- This applies to all explanations, reports, and discussions
- Code comments and commit messages follow their own rules (see below)

## Source Code Comment Language
**All comments inside source code files (.rb, etc.) must be in English.**
- This includes inline comments, block comments, and YARD doc comments.
- Error/exception message strings in `raise` statements must also be in English.
- Japanese must NOT appear in any source code file under `lib/` or `spec/`.
- This rule exists to keep the OSS codebase accessible to international contributors.

## GitHub Communication Policy
**All GitHub comments must be in English.**
- This includes (but is not limited to) PR reviews, PR/issue comments, and PR descriptions.
- This rule is separate from the chat language policy above.

## Important Notice
**Always check this file**:
- At the start of each conversation
- After context summary
- Before important operations (commit, release, etc.)

## Git Repository Location
- The main git repository is located at: `/home/raizo-tcs/ruby_ai_agent_framework/phronomy`
- When performing git operations, always use this directory as the working directory

## Testing
- After editing repository files, always run the test suite to verify changes:
  ```bash
  cd /home/raizo-tcs/ruby_ai_agent_framework/phronomy && \
    export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH" && \
    bundle exec rspec --format documentation
  ```
- All tests must pass before committing changes
- If tests fail, always investigate and identify the root cause before making any fixes
- Report the cause of test failures before applying corrections

## Commit Rules (MANDATORY)
- **Never run `git commit` or `git push` without explicit user approval.**
  - Even after tests pass and changes look complete, stop and present the diff/summary to the user, then wait for an instruction such as "commit", "push", "OK", or equivalent before proceeding.
  - This applies to every commit/push, including follow-up "fix CI" commits.
  - The user's silence is NOT consent.
- Always run the full test suite before proposing a commit and resolve any failures:
  ```bash
  bundle exec rspec
  ```
- These requirements may be skipped only when the user explicitly grants permission.
- Commit messages must be in English to maintain consistency for the OSS project.
- For release/version update commits, always use the `bump ...` style message format (e.g., `bump version to X.Y.Z`).
- After every commit/push you perform, actively monitor the corresponding GitHub Actions runs and address any resulting errors before moving on to other work.
- Before pushing new changes, always cancel any currently running workflows for the same branch to save resources and avoid confusion.

## Diagnosis Discipline (MANDATORY)
- When CI or tests fail, **identify the true root cause before applying fixes.**
  - Do not narrow supported versions, skip tests, or relax constraints as a shortcut to make CI green.
  - Examples of unacceptable shortcuts: dropping Ruby versions from a matrix to avoid a lockfile resolution issue, adding broad `rubocop:disable` comments instead of fixing the real style problem, deleting failing tests instead of debugging them.
  - If the root cause is unclear, report findings and ask the user before changing project-wide constraints (gemspec, CI matrix, public API, etc.).
- For Ruby gems specifically: `Gemfile.lock` should typically NOT be committed for library projects (it pins default-gem versions to the developer's local Ruby patch level and breaks CI on other patch levels).

## External Reference Verification
- When referencing external URLs or web documentation, always use the browser MCP tools to verify content
- Do not rely solely on `fetch_webpage` for important technical documentation

## Code Modification Rules (CRITICAL)
- **NEVER make speculative fixes without explicit user approval**
- **SUPER IMPORTANT: Do NOT fix based on possibilities. Always confirm the phenomenon first**
  - Reproduce locally if possible, or add instrumentation to surface the exact failing condition.
  - Only after you have concrete evidence propose and apply the minimal fix.
- When encountering errors or issues:
  1. Report the issue and analysis
  2. Propose potential solutions
  3. Wait for user's decision
  4. Only then implement the approved solution
- Exception: Build/compile errors may be fixed immediately
