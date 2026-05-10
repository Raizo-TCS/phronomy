# Phronomy — Multi-Agent Handoff & Runner

## 1. Overview

The Handoff/Runner system enables multi-agent workflows where agents can
transfer a conversation to a more specialised agent. The transfer is transparent
to the end user — they see one continuous conversation.

This is distinct from the Agent-as-Tool pattern (where an orchestrator LLM
explicitly calls a sub-agent tool). In the Handoff pattern, the active agent
itself decides to transfer control, and the `Runner` coordinates the routing.

```
User input
    │
Runner.invoke(input)
    │
[Entry Agent]  ──transfer_to_billing──→  [BillingAgent]
                                               │
                                        final answer
```

---

## 2. Components

### 2.1 Handoff

`lib/phronomy/agent/handoff.rb`

Represents a directed transfer edge from one agent to another. Internally it
creates an anonymous `Phronomy::Tool::Base` subclass with the name
`transfer_to_<snake_case_agent_class>`.

When the LLM in the source agent decides to hand off, it calls this tool. The
tool returns a **sentinel string** (`"__PHRONOMY_HANDOFF__:<TargetClassName>"`)
which `Runner` detects to identify the next agent.

```ruby
handoff = Phronomy::Agent::Handoff.new(
  target_agent: billing_agent,
  description:  "Transfer to BillingAgent."  # optional override
)
tool_class = handoff.to_tool_class   # anonymous Tool::Base subclass
```

### 2.2 Runner

`lib/phronomy/agent/runner.rb`

Orchestrates invocations across a pool of agents. On each `#invoke` call it:

1. Invokes the current agent with the user input
2. Scans returned messages for a handoff sentinel (most recent `:tool` message)
3. If a sentinel is found, switches to the target agent and loops
4. Stops when no handoff is detected or `MAX_HANDOFFS` (20) is exceeded

```ruby
runner = Phronomy::Agent::Runner.new(
  agents: [triage, billing, support],    # first agent is the entry point
  routes: {
    triage  => [billing, support],       # triage may hand off to either
    billing => [triage],                 # billing can hand back to triage
    support => [triage]
  }
)

result = runner.invoke("I need help with my invoice", config: { thread_id: "c1" })
result[:output]  # => final answer string
result[:agent]   # => the agent that produced the final answer
```

---

## 3. Registration API

### Class-level DSL

```ruby
class TriageAgent < Phronomy::Agent::Base
  model "gpt-4o"
  instructions "Route the user to the appropriate department."
  handoffs BillingAgent, SupportAgent   # classes or instances
end
```

### Instance-level registration

```ruby
triage  = TriageAgent.new
billing = BillingAgent.new
support = SupportAgent.new

runner = Phronomy::Agent::Runner.new(
  agents: [triage, billing, support],
  routes: { triage => [billing, support] }
)
```

`Runner#build_handoffs` calls `source_agent._add_handoff_tool(tool_class)` for
each route, injecting the generated `transfer_to_*` tool at runtime.

---

## 4. Handoff Detection

After each agent invocation, `Runner` scans messages in reverse order:

```ruby
messages.reverse_each do |msg|
  next unless msg.role.to_sym == :tool
  next unless msg.content.to_s.start_with?("__PHRONOMY_HANDOFF__")
  return @sentinel_map[msg.content]   # look up target agent
end
```

The sentinel map is built at construction time:
`sentinel → target_agent_instance`.

---

## 5. Safety Limits

| Limit | Value | Behaviour on breach |
|-------|-------|---------------------|
| `MAX_HANDOFFS` | 20 | Raises `Phronomy::HandoffError` |

This prevents infinite handoff loops (e.g. triage ↔ billing in a cycle).

---

## 6. Topology Patterns

### Hub-and-spoke (recommended)

```
            TriageAgent (entry)
           /          \
     BillingAgent   SupportAgent
           \          /
            TriageAgent (back-route)
```

### Linear

```
IntakeAgent → AnalysisAgent → ReportAgent → (no further handoff)
```

### Arbitrary graph

Any DAG or cyclic graph is supported. The `MAX_HANDOFFS` limit prevents
infinite loops.

---

## 7. Result Schema

`Runner#invoke` returns a Hash:

```ruby
{
  output:   "Your invoice total is $42.",  # String
  messages: [...],                          # full message history from last agent
  usage:    Phronomy::TokenUsage,           # or nil
  agent:    <BillingAgent instance>         # the agent that produced the output
}
```

---

## 8. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Sentinel string in tool result | Avoids modifying the Agent::Base invoke return shape; works with existing message history |
| Anonymous tool class per Handoff | No name collision; the tool class is owned by the Handoff instance |
| First element of `agents:` is entry point | Explicit; no "primary" flag needed |
| MAX_HANDOFFS = 20 | High enough for real workflows; low enough to catch runaway loops |
| `routes:` hash separate from `agents:` | Decouples agent registration from routing topology |
