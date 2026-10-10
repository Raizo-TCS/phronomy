# Failure reason codes

`Phronomy::Error` and its subclasses accept an optional `code:` String and expose
it through `error.code`. Unspecified codes are nil. Supplied strings are copied
and frozen. Existing message, class, cause and backtrace behavior is retained.
No change is made to StandardError or third-party exceptions.

This is an additive public-contract extension. `class` and `message` remain in
saved failure diagnostics. When a Phronomy exception has a code, its diagnostic
also contains `"code"`. The same generic field is retained through Agent failure
persistence, Team results, and terminal resume/reboot. A code is not an execution
status and is not a retry permission.

| Code | Owner and meaning |
|---|---|
| `team.enqueue_after_finalize` | MultiAgent: a new enqueue was conclusively rejected after finalization, following the existing readback checks |

The operation wrapper remains catchable as ConfigurationError. A Team's aggregate
failure remains a Phronomy::Error and now carries the stored code. An operation
that already succeeded with the same identity still replays its original result.
Unknown persistence outcomes and readback failures remain recovery requirements;
an inner code is not blindly copied onto that outer uncertainty.

The application may choose to retry only a durably failed planning attempt:

```ruby
outcome && outcome[:status] == "failed" &&
  outcome.dig(:error, "code") == "team.enqueue_after_finalize"
```

Example 21 retains its four-section/content-length validator and existing retry
limit. That application policy is not part of the reason code contract.

## Compatibility

No SQL columns or record-format versions change. Error diagnostics are content
JSON; the existing content codec carries the optional field without interpreting
it. Old diagnostics without codes remain readable. Unknown string codes are
preserved, and no code is inferred from a message.

A v0.28.0 reader can inspect the extra JSON field through stored result data.
Its reconstructed exceptions do not expose the new code, and paths that rebuild
a failure from class/message can lose it. Mixed-version writes and code-based
exception handling on an old reader are therefore unsupported. Upgrade consumers
before relying on codes; there is no automatic historical backfill.
