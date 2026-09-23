# RubyLLM 2.0 and token ownership (Refactor 45)

This candidate targets RubyLLM 2.0.x (`~> 2.0.0`), verified with 2.0.0.
It implements the previously deferred token-ownership plan against the current
0.26.0 refactoring branch. It does not publish or renumber the Phronomy gem.

## Ownership

| Concern | Owner and behavior |
|---|---|
| Input capability | RubyLLM model registry `context_window`, defined by RubyLLM 2 as maximum input tokens |
| Model lookup | `RubyLLM.models.find(model, provider: provider)` |
| Input budget | Phronomy `TokenBudget(max_input_tokens:)`, using that limit directly |
| Unknown/invalid input limit | No hard token budget; no invented limit or reserve |
| Requested output cap | Agent `max_output_tokens`, positive Integer; stored in model_config |
| Output request rendering | RubyLLM `Chat#with_max_output_tokens`; all wire names remain upstream |
| Context selection | Phronomy ContextPolicy and final Manifest validation |
| Replay | Recorded Manifest segments and request intent; no current-budget reselection |

Remove application calls to `Agent.context_window` and
`configuration.default_output_reserve`. They no longer exist.
`before_llm_input` patches containing `context_window` raise ConfigurationError;
register custom/local model metadata through RubyLLM's public registry loader.
`max_output_tokens` does not reduce the input budget and is not inferred from
registry output capacity. Omit it to use RubyLLM/provider defaults.
The obsolete InvalidContextBudgetConfigurationError has also been removed.
New manifests have assembly policy version 9. Historical model_config keys are
not rewritten during materialization, and the runtime builder forwards only
supported request settings.

## RubyLLM 2 compatibility

The adapter uses `with_tools`, keyword Tool execution, `parameters_schema`,
`provider_options`, `Message#model`, and `Tokens#cache_read/#cache_write`.
Phronomy's `param`, `params`, `with_params`, `params_schema`, and `provider_params`
remain available as its own Tool contract. RubyLLM 2's derived class tool name
is used when no explicit name is supplied. Structured historical content is
encoded as JSON text when materialized into RubyLLM 2 Messages. Stored canonical
content is unchanged. Phronomy TokenUsage retains its cached/cache_creation names;
recovery reads both the historical and new RubyLLM counter keys.

Cached instructions use `with_instructions(..., cache_until_here:)`.
No RubyLLM 1.x guard, monkeypatch, or provider-specific output mapping remains.
Applications choose protocol settings in RubyLLM. Its OpenAI default is Responses;
local Chat Completions endpoints must configure `openai_protocol = :chat_completions`.

Tool batches are intercepted through `after_message`, after RubyLLM has appended
the complete assistant Message and before RubyLLM's approval/Tool execution loop.
Phronomy's existing authorization, suspension and batch execution paths therefore
remain authoritative. Tool classes and their approval declarations are not
rewritten to bypass RubyLLM's gate.

## Saved Tool definitions and deployment

The previous empty-schema fallback concealed argument changes. New definitions
record the actual schema and provider options and compare them canonically.
Changes to argument type, requiredness, enum or provider options are rejected.

An old `{}` schema cannot establish which parameters were originally authorized.
The migration fails closed with an explicit diagnostic when such a saved
Manifest is materialized; it does not synthesize or weaken historical definitions.
Before updating, finish outstanding Agent, Workflow and Team operations that may
need old Tool-bearing manifests on the old core/RubyLLM combination, and retain
backups of durable storage. Do not perform a rolling upgrade with mixed versions
sharing those in-flight executions. Completed history is not rewritten; starting
a new invocation creates a current schema-bearing manifest. This is a deployment
boundary, not an automatic historical-data repair.

## Examples and verification

The shared examples configuration registers explicit PHRONOMY_CONTEXT_WINDOW or
observed local metadata via `RubyLLM.models.load_from_json`, retaining other model
entries. An unavailable local limit remains nil, including when the local server
uses a cloud model's name. Code-review chunking requires known metadata explicitly.
Request output caps are independent constants. Rails examples use the same setup.

Tests cover provider-qualified input budgets, missing metadata, output forwarding,
forbidden hook overrides, saved intent without reselection, actual Tool schema
comparison, old/new usage counters, Responses Tool/approval/streaming execution,
and existing Chat Completions and durability behavior. Protocol rendering remains
RubyLLM's responsibility. Distribution evidence distinguishes HTTP stubs and local
SQLite from live providers, PostgreSQL and the remote Ruby-version CI matrix.
