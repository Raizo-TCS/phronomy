> **ARCHIVED / non-normative**
>
> This removed/obsolete design is retained only as historical reference. It is
> not a current architecture or public-API contract. Start at
> [docs/architecture.md](../../../architecture.md) and the
> [ADR index](../../../decisions/README.md).

# Phronomy — Guardrail System

## 1. Overview

Guardrails are validation hooks that intercept agent inputs and outputs before
they reach (or leave) the LLM. They provide a clean interception point for
safety, compliance, and data-quality concerns without modifying core agent logic.

```
User input
    │
[InputGuardrail x N]     ← raises GuardrailError on failure
    │
    LLM
    │
[OutputGuardrail x N]    ← raises GuardrailError on failure
    │
Agent result
```

Multiple guardrails of each type may be registered per agent and are executed
in registration order. The first failure short-circuits the remaining guardrails.

---

## 2. Base Class

`lib/phronomy/guardrail/base.rb`

```ruby
class Phronomy::Guardrail::Base
  def check(value)       # subclasses implement this
  def run!(value)        # calls check; returns value unchanged on success
  protected def fail!(reason)  # raises Phronomy::GuardrailError
end
```

`GuardrailError` is a standard Ruby exception. It carries:
- `message` — the human-readable rejection reason
- `guardrail` — the guardrail instance that raised

---

## 3. InputGuardrail

`lib/phronomy/guardrail/input_guardrail.rb`

Applied to user input **before** the LLM receives it.

```ruby
class NoCreditCardGuardrail < Phronomy::Guardrail::InputGuardrail
  def check(input)
    fail!("Credit card numbers are not allowed") if input.to_s.match?(/\d{4}[- ]\d{4}[- ]\d{4}[- ]\d{4}/)
  end
end

agent.add_input_guardrail(NoCreditCardGuardrail.new)
```

---

## 4. OutputGuardrail

`lib/phronomy/guardrail/output_guardrail.rb`

Applied to the LLM's output **before** it is returned to the caller.

```ruby
class NoURLGuardrail < Phronomy::Guardrail::OutputGuardrail
  def check(output)
    fail!("Output must not contain URLs") if output.to_s.match?(/https?:\/\//)
  end
end

agent.add_output_guardrail(NoURLGuardrail.new)
```

---

## 5. Registration API

Guardrails are registered on agent instances or via the class-level DSL:

```ruby
# Instance registration
agent = MyAgent.new
agent.add_input_guardrail(PIIPatternDetector.new)
agent.add_output_guardrail(NoURLGuardrail.new)

# Class-level DSL (applied to all instances)
class MyAgent < Phronomy::Agent::Base
  input_guardrail  Phronomy::Guardrail::Builtin::PIIPatternDetector.new
  output_guardrail Phronomy::Guardrail::Builtin::PromptInjectionDetector.new
end
```

---

## 6. Built-in Guardrails

`lib/phronomy/guardrail/builtin/`

### 6.1 PIIPatternDetector

`Phronomy::Guardrail::Builtin::PIIPatternDetector`

Detects common PII patterns in the input string via regex (no LLM call).

**Categories** (all active by default, each individually toggleable):

| Key | Pattern | Description |
|-----|---------|-------------|
| `:ssn` | `\d{3}-\d{2}-\d{4}` (hyphens required) | US Social Security Number |
| `:credit_card` | 16 digits optionally space/hyphen separated | Credit/debit card |
| `:email` | RFC 5322 simplified | Email address |
| `:phone` | 3-digit area code + 3–4-digit exchange + 4-digit subscriber; optional E.164 prefix | Phone number |

```ruby
# All categories (default)
Phronomy::Guardrail::Builtin::PIIPatternDetector.new

# Only email and credit card
Phronomy::Guardrail::Builtin::PIIPatternDetector.new(
  detect: [:email, :credit_card]
)
```

### 6.2 PromptInjectionDetector

`Phronomy::Guardrail::Builtin::PromptInjectionDetector`

Detects common prompt injection phrases via a built-in regex list.

**Default patterns include:**
- `ignore all previous instructions`
- `disregard prior rules`
- `forget above prompts`
- `system prompt:`
- `you are now a/an ...`
- `act as a/an ...`
- `pretend you are ...`
- `jailbreak`, `DAN mode`, `developer mode`

```ruby
# Default patterns only
Phronomy::Guardrail::Builtin::PromptInjectionDetector.new

# With additional custom patterns
Phronomy::Guardrail::Builtin::PromptInjectionDetector.new(
  additional_patterns: [/do anything now/i, /DAN/]
)
```

---

## 7. Error Handling

When a guardrail fails, `Phronomy::GuardrailError` is raised. Callers should
rescue this exception to provide user-facing error messages:

```ruby
begin
  result = agent.invoke(user_input)
rescue Phronomy::GuardrailError => e
  puts "Request blocked: #{e.message}"
end
```

---

## 8. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Separate Input/Output subclasses | Makes type intent explicit; avoids guards accidentally applied to wrong phase |
| `run!` calls `check` | Decouples the check logic from error-raising boilerplate |
| Built-in PII detector uses regex only | Zero LLM cost; sufficient for structured PII like credit cards and My Number |
| `fail!` raises immediately | Short-circuits remaining guardrails; fail-fast semantics are safer |
| Multiple guardrails per agent | Composable; each guardrail has a single responsibility |
