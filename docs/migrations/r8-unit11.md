# Migrating to r8 unit 11

Apply after core eaff581cb8806c707d47649bb561b70690fa9e57 (unit 10).
This package changes core only. The unit 6 examples at
ed455c52018338f7c5a4c2948ae0d7db131aa090 require no source changes.

No application API changes or database migrations are required. Continue to
load the library with require "phronomy" and use the existing context_policy
DSL for explicit policies. The boot composition installs DefaultPolicy through
that same DSL. Reading an unconfigured internal Base now fails explicitly
instead of selecting a concrete Policy inside Agent.

| Private implementation use | Replacement |
| --- | --- |
| Agent::Base concrete Policy fallback | runtime_composition/agent_defaults.rb installs the default |
| InvocationActions constructs LLMAdapter::AsyncClient | Its captured environment.build_llm_client(adapter: ...) |
| Agent LLM submission resolves the current global Runtime | EngineEnvironment binds the client to its retained Runtime |
| AsyncClient constructor | Optional submitter: using existing _ExecutionSubmitter; existing arguments still work |

Internal custom ExecutionEnvironment implementations must supply the new client
capability. It is not a supported application extension API. Clients created
without an injected submitter preserve their default Runtime behavior; explicit
pool arguments preserve precedence. Changing the global default Runtime does
not migrate an existing Agent's resources. Follow the existing stop/drain and
recreate procedure when replacing running processes.

The ZIP contains complete changed files, strict-base application and expected-tree
verification, a review patch, test evidence and recovery instructions. Run
--check, --apply and --verify in a new worktree, then --verify after commit.

For examples verification, unset BUNDLE_GEMFILE before entering the examples
checkout and set PHRONOMY_PATH to this core. Inspect and restore only generated
lockfile/vendor changes; no examples commit is needed.
