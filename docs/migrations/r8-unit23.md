# r8 unit23 migration

This is a core-only responsibility refactor on applied unit22.

- `Tools::Agent.from_agent`, synchronous `execute`, asynchronous `call_async`
  and the public `Agent.run_once` API retain their signatures and behavior.
- Agent Tool calls still create a fresh Agent and ephemeral store. Configured
  application stores do not replace this per-call store.
- `Testing::Eval::Scorer::LlmJudge` retains its constructor and scoring API.
  Configure `llm_adapter` through the existing application configuration API.
- LlmJudge reads the default adapter for each score, after preparing its Request.
  Existing scoped configuration and reset behavior are retained.
- The client factory is an internal boot binding. Applications do not need to
  register it or adopt a new factory API.
- No Contract, Execution, Engine, RBS, data schema or stored-record migration is
  required. Examples require verification only, with no source changes.

Use the package README to check the exact base commit, apply complete files,
verify the resulting tree, run the validation commands and commit the result.
Normal application loading remains `require "phronomy"`.
