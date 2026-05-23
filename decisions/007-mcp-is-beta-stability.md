# ADR-007: MCP Tool Support Is Classified as Beta Stability

## Status

Accepted

## Context

Phronomy's `McpTool` integrates with the Model Context Protocol (MCP), allowing
agents to call tools exposed by external MCP servers over stdio or HTTP. The
protocol specification is still evolving (as of 2025), and the surface area of
the integration is large:

- Two transports: `StdioTransport` and `HttpTransport`
- JSON-RPC 2.0 framing, capability negotiation, tool listing, tool invocation
- Custom authentication headers, environment forwarding, startup timeouts

The phronomy README stability table uses three tiers: **Stable**, **Beta**, and
**Experimental**. The distinction matters because:

- **Stable** APIs are covered by the public API compatibility snapshot (#210)
  and breaking changes require a major version bump.
- **Beta** APIs can change between minor versions with a CHANGELOG entry.
- **Experimental** APIs can change between patch versions without notice.

Classifying MCP as Stable would lock in the current API before the protocol and
integration have been exercised in production at scale. Classifying it as
Experimental would be too conservative — the API is intentionally designed and
documented.

## Decision

`McpTool` and its transport classes (`StdioTransport`, `HttpTransport`) are
classified as **Beta** in the README stability table and in YARD documentation.

This signals:
- The interface is intentional and useful but may change as MCP specification
  and real-world usage reveal gaps.
- Users should pin minor versions when using MCP in production.

## Consequences

**Positive:**
- Honest representation of the API maturity.
- Allows breaking changes (e.g., richer error types, capability negotiation
  changes) between minor versions without a major bump.

**Negative / Tradeoffs:**
- Some users may avoid a Beta-labeled feature in production. Documentation
  should clarify that "Beta" reflects protocol evolution risk, not
  implementation quality.
