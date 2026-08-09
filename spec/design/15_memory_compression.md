# Memory Compression — Archived Design

> **ARCHIVED**
>
> This document previously specified mutable conversation-memory compression
> that replaced old messages with synthetic summaries. That model conflicts with
> the current append-only Journal / Manifest-selection authority model and is no
> longer an active design.

Current Context reduction is performed by selecting or omitting logical Context
units from each Manifest. Raw Journal records are not deleted or replaced.
Future deterministic derived summaries/compaction, if introduced, must be
specified as a separate Journal/Context Policy design and must preserve source
provenance and append-only raw history.

See `07_context_management.md` and ADR-012.
