# Phronomy — Before-Completion Hook

## 1. Overview

The `before_completion` hook allows user code to inspect and modify the
parameters sent to the LLM immediately before `chat.ask` is called. It is the
primary extension point for dynamic parameter injection: injecting per-request
`temperature`, overriding `model`, adding `response_format`, etc.

---

## 2. Hook Context

`lib/phronomy/agent/before_completion_context.rb`

An immutable value object passed to each hook:

```ruby
Phronomy::Agent::BeforeCompletionContext.new(
  agent:    self,           # Agent::Base instance (read-only)
  messages: [...],          # Array of message hashes (read-only snapshot)
  config:   { ... },        # invocation config hash (read-only)
  params:   { model: "x" }  # current accumulated params (read-only)
)
```

All four attributes are read-only. Hooks must not mutate them; instead, they
return a Hash to be deep-merged.

---

## 3. Hook Tiers

Hooks are registered at three tiers and executed in order. Later tiers take
precedence on key conflicts (deep-merge, last wins).

| Tier | Registration | Scope |
|------|-------------|-------|
| **Global** | `Phronomy.configuration.before_completion = lambda { ... }` | All agents, all invocations |
| **Class** | `before_completion ->(ctx) { ... }` DSL in agent class body | All instances of that class |
| **Instance** | `agent.before_completion = ->(ctx) { ... }` | Single agent instance |

Execution order: **Global → Class → Instance**

---

## 4. Registration Examples

### Global hook (initialiser)

```ruby
Phronomy.configure do |c|
  c.before_completion = lambda do |ctx|
    { temperature: 0.3 }   # apply to every LLM call
  end
end
```

### Class-level DSL

```ruby
class MyAgent < Phronomy::Agent::Base
  model "gpt-4o"

  before_completion ->(ctx) {
    { temperature: ctx.config[:precise] ? 0.0 : 0.7 }
  }
end
```

### Instance-level

```ruby
agent = MyAgent.new
agent.before_completion = ->(ctx) { { max_tokens: 512 } }
```

---

## 5. Hook Return Value

| Return value | Effect |
|-------------|--------|
| `Hash` | Deep-merged into accumulated params |
| `nil` | Ignored; params pass through unchanged |
| `{}` | No-op; params pass through unchanged |

---

## 6. Invocation in Agent::Base

Called in both `invoke_once` (single-turn) and `stream` (streaming), after the
chat object is built but before `chat.ask`:

```ruby
def apply_before_completion_hooks(ctx)
  [
    Phronomy.configuration.before_completion,
    self.class._before_completion_hook,
    @before_completion
  ].compact.each_with_object({}) do |hook, acc|
    result = hook.call(ctx)
    acc.merge!(result) if result.is_a?(Hash)
  end
end

# In invoke_once:
extra_params = apply_before_completion_hooks(ctx)
chat.ask(messages, **base_params.merge(extra_params))
```

---

## 7. Use Cases

### Dynamic temperature by intent

```ruby
before_completion ->(ctx) {
  terse = ctx.messages.last[:content].to_s.length < 30
  { temperature: terse ? 0.2 : 0.8 }
}
```

### JSON mode for structured agents

```ruby
before_completion ->(ctx) {
  { response_format: { type: "json_object" } }
}
```

### Request-scoped model override

```ruby
agent.before_completion = ->(ctx) {
  { model: ctx.config[:fast] ? "gpt-4o-mini" : "gpt-4o" }
}
```

---

## 8. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Three tiers | Supports framework-wide defaults, per-class behaviour, and per-instance overrides without requiring subclassing for each variation |
| Immutable context | Prevents hook ordering from mattering for observation; side effects via return value only |
| Deep-merge (last wins) | Instance hook can always override class/global defaults |
| Called before `chat.ask`, not before message assembly | Hook sees the final message list but cannot modify it — separation of concerns |
| `nil` return is a no-op | Hook can conditionally apply changes without always returning a Hash |
| Lambdas (not blocks) | Stored as callable objects on class/instance variables; composable and testable |
