# R8 unit 9 migration

Apply to core unit 8, commit e9f6cc16da19be82a0b7777486926ba46d070def.
Examples source remains at unit 6, ed455c52018338f7c5a4c2948ae0d7db131aa090.

No public Tool or Agent signature, stored schema, migration CLI or example source
change is required. Existing configured filter order and repeated registrations
are preserved. The correction removes only the extra transformation caused by
Base's standard async-to-sync delegation under a custom async result decorator.

A custom call_async using super now passes its raw delegated result through its
own processing before the async decorator applies the configured transform.
Code accidentally relying on the duplicate/intermediate transformation should
express the required stages explicitly in application filter configuration.

A custom call_async explicitly calling public call retains that call's filters;
the enclosing async result decorator also retains its stage. Do not substitute
call for super when the intent is to delegate to Base's normal async execution.
The framework does not suppress application-authored calls or infer their intent.

Private changes: Base uses Tool::Operation.synchronous_delegate; ToolExecutor
accepts a bound synchronous_call keyword. Applications should not use these
private bridge helpers. Custom async implementations retain their existing
execution mechanism and keyword protocol.

Use the normal process stop/drain and restart procedure. This unit does not add
cross-version in-flight compatibility or rollback of external Tool side effects.
See docs/architecture/r8-unit9.md for operation-boundary examples.
