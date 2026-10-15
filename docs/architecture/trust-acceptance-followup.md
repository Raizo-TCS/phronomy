# Trust pipeline acceptance follow-up

## Purpose and responsibility

Communication integrity, schema validity and business truth are different
promises. Successful HTTP and valid JSON cannot establish faithful extraction.

| Concern | Owner | Change |
| --- | --- | --- |
| HTTP status and configured retries | HTTP stack / concrete RubyLLM backend | Require a verified stack that preserves streaming status |
| Schema-valid terminal values | Agent, using OutputParser | Existing guarantee retained |
| Evaluation criteria and result meaning | GeneratorVerifier | Existing protocol retained |
| Exact invoice extraction | Application / acceptance oracle | Reject incorrect values explicitly |
| Approval decision and Tool effects | Application decision, Agent execution, Generation routing | Observe notification, decision, effects and release |
| Unexplained wait | Diagnostic runner plus server logs | Record payload, settings, attempts and periodic thread stacks |

Contract owners, their dependencies, Engine and Execution are unchanged.
No SDK monkey patch, extra retry loop, output repair or schema downgrade is added.

## HTTP dependency correction

Faraday 2.1.0 with faraday-net_http 2.1.0 did not pass the response environment to
streaming callbacks. RubyLLM 2.0.0 could interpret a JSON 400 as a synthetic 500.
401 and 429 could also lose their identity. The ServerError fallback additionally
misclassified an actual 500 whose text matched the known schema rejection.

Supported floors are now Faraday 2.14.4 and faraday-net_http 3.4.4, the pair
already verified on the normal path. Both are explicit in the gemspec: raising
Faraday alone does not exclude older Net::HTTP adapters. CI pins and checks both,
with the existing minimum RubyLLM, MCP and JSON versions. These are verified
support floors, not claims about the earliest upstream fix. Custom Faraday
adapters need their own streaming/status compatibility assessment.

The obsolete ServerError fallback is removed. Only a real BadRequestError with
the known body becomes StructuredOutputUnsupportedError. Actual 500 responses
retain the SDK server-error cause. Configured SDK retries for 429/500 remain;
a 400 rejection is one HTTP attempt even with three retries configured.
Partial-stream replay and callback identity regressions remain in place.

Before and after, application handling uses the same public API:

```ruby
rescue Phronomy::LLMAdapter::StructuredOutputUnsupportedError => error
  warn error.cause.class
```

Before, the old stack could issue four requests and expose a synthetic ServerError
for HTTP 400. After, the cause is BadRequestError and that rejection is not
retried as a transient server failure.

## Content fidelity and acceptance

The invoice demo keeps its general string/number schema and asks the model to
preserve identifier characters. After Agent release, an independent oracle checks
the fixed fixture. Incorrect values exit 1; they are never replaced or retried.
This is fixture acceptance, not a general invoice validator or Agent responsibility.

Before, INV-2026-01 could print and exit successfully for source INV-2026-001.
After, it is a fidelity failure, while schema validation remains correctly
successful. One correct response does not establish general model accuracy.

The examples runner checks invoice, accepted, iteration_limit and approval
yes/no/cancel independently. Approval requires a notification and the expected
Tool effects. A schema/Tool rejection is blocked, not successful approval.
Yes checks approval and valid completion; accepted is a separate test because
Tool approval does not guarantee that evaluation criteria will be satisfied.

## Wait diagnosis and limits

The opt-in runner observes the pinned SDK without replacing the provider or
changing timeout/retry settings. It records UTC times, request payloads/hashes,
settings, physical HTTP attempts, results, exception causes, releases and periodic
Ruby thread stacks. Observer failures invalidate the report and do not replace
the application exception. Signals wrapped by cleanup errors remain interrupted.

Observation uses diagnostic-only SDK method bindings and must be reviewed when
the SDK changes. Reports contain prompts/responses. Sampling and file writes add
overhead; this runner is not a performance benchmark.

Historical LM Studio logs cannot be reconstructed. Match the saved review payload
and UTC times with server logs; use future wait stacks to identify pending
HTTP/SDK/framework operations before assigning a cause. A later fast response
does not resolve the earlier wait.

Controlled HTTP fixtures prove framework and observation behavior, not live
model accuracy or server support for schema plus Tools. Live acceptance still
requires a suitable model/server environment and recorded server version.
