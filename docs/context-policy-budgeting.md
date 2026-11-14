# Context Policy budgeting

Applications choose how much model input capacity to use for one selection.
Context exposes that capacity and candidate estimates, while the framework keeps
its internal budget representation and final input validation.

For example, a review Policy can reserve part of the available input for its own
safety margin, then let DefaultPolicy choose history within the smaller limit.
No application needs to construct a private budget object for that operation.

## Reading and constraining input limits

A Policy input reports its current selection limit and can derive another input
with a smaller limit. Derivation preserves the original input and all its
material; it does not change model capabilities or generation settings.

For example, an input with a limit of 8192 can produce a selection input capped
at 5632. The original input still reports 8192. The derived input cannot later
increase its limit above 5632.

```ruby
require "phronomy"

class ReservedInputPolicy < Phronomy::Context::ContextPolicy
  def call(input)
    limit = input.input_token_limit
    unless limit
      raise Phronomy::ConfigurationError, "Review requires known model input capacity"
    end

    selection_limit = limit - limit / 4 - limit / 16
    selected_input = input.with_input_token_limit(selection_limit)
    Phronomy::Context::DefaultPolicy.instance.call(selected_input)
  end
end
```

`input_token_limit` returns an Integer or `nil` for an unknown limit.
`with_input_token_limit(limit)` requires a positive Integer without coercion;
zero, negative values, strings and floating-point values raise `ArgumentError`.
Increasing a known limit also raises `ArgumentError`. The returned
`ContextPolicyInput` is immutable, and its other field values are unchanged.

When the original limit is unknown, an explicit positive selection cap is
allowed. That cap expresses application policy and does not establish that the
model can accept that input. Applications that require known capability must
reject `nil`, as the example above does.

The cap controls selection performed with the derived input. The framework's
final validation still uses the actual model budget; returning a different Plan
does not make the derived cap a new global validator. It does not set an output
token limit, alter a saved Manifest, or affect another Agent call.

## Estimating candidate content

A Policy can estimate proposed content through the same canonical encoding and
estimator used by its generated items. The Policy remains responsible for
choosing complete items and preserving required conversation groups.

For example, a retrieval Policy can fit a JSON page before adding it as
knowledge. JSON escaping contributes to the estimate because the complete
serialized page is measured.

```ruby
require "phronomy"
require "json"

class PageKnowledgePolicy < Phronomy::Context::ContextPolicy
  def initialize(page:, allowance:)
    @page = page
    @allowance = allowance
  end

  def call(input)
    content = JSON.generate(@page)
    if estimate_tokens(content) > @allowance
      raise Phronomy::Context::BudgetExceededError, "Retrieved page exceeds its allowance"
    end

    page = knowledge_item(content: content, required: true)
    Phronomy::Context::DefaultPolicy.instance.call(
      input.with(knowledge: input.knowledge + [page])
    )
  end
end
```

`estimate_tokens(content)` is a protected subclass helper. Strings are estimated
as text; other values use the framework's canonical JSON encoding. The helper
uses the existing estimator and does not introduce a second token-counting
algorithm. Estimates are approximate unless the configured estimator provides
model-specific counts. A successful estimate does not guarantee provider
acceptance or replace final input validation.

## Compatibility and ownership

These operations belong to the Context contract and reuse its existing budget
and estimation mechanisms. Applications own allocation ratios and retrieval
policy; DefaultPolicy retains its current selection algorithm.

For example, Example 22 can budget retrieved findings through these operations
while SharedState continues to coordinate Agents and application Tools continue
to own the finding store. No SharedState-to-Context dependency is introduced.

The operations are Experimental and available since v0.33.0. Existing private
budget and estimation classes remain implementation details. Existing ContextPolicy
factories and DefaultPolicy behavior are unchanged, and the protected helper
applies equally to normal Agent calls and SharedState member calls.
