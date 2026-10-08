# r8 unit21 migration

This core-only responsibility refactor requires no application or stored-data
migration. Continue using Phronomy.configure with tool_result_max_size, tracer
and trace_pii, and the existing per-Tool max_result_size option. Public defaults,
nil semantics, read timing, truncation and redaction behavior remain unchanged.
Application-configured filter order and repetition remain unchanged too.

Tool and Tracing now obtain their settings through their own internal value
containers. Context::Assembly obtains its default tracer from Tracing while
retaining explicit injection and constructor-time selection. Composition still
selects concrete defaults and supplies current values; no manual per-operation
injection or settings-change subscription is required.

Internal tests or unsupported integrations constructing RuntimeSettings must
stop passing tracer: to its constructor or reading tracer, trace_pii and
tool_result_max_size from it. Ordinary application code should use the unchanged
public Configuration accessors. Its private instance variables and the new
domain settings containers are not an application extension API.

Apply from unit20 commit `bda5da03da5a4da33041953cf0eebaa32de7bb81` in a new
`refactor/r8-unit21` worktree using the package's checked applier. Verify the
expected tree before and after committing. Follow the existing shutdown/drain
procedure when replacing running code. Examples remain on their unit6 sources
and are verified against this core through PHRONOMY_PATH.

No data rollback is needed. Reverting this commit restores the earlier settings
ownership; it does not remove the unit19/20 Engine corrections.
