# Phronomy — Design Decision Log

A record of design decisions and their rationale. Use this as a reference when revisiting decisions later.

---

## Decision 1: Adopt RubyLLM as the LLM abstraction layer

**Situation**: Needed to choose between a custom implementation and RubyLLM as the backend for Phronomy.

**Choice**: Adopt RubyLLM.

**Rationale**:
- Provider support (13+) is already implemented, greatly reducing Phronomy's development cost
- Rails/ActiveRecord integration, streaming, and model registry — all foundations Phronomy needs — are in place
- Natural Ruby DSL code can be written, which aligns well with Phronomy's DSL
- Alternatives (direct Faraday, OpenAI gem only) offer poor return on investment compared to focusing on implementing LangGraph-equivalent features

**Trade-offs**:
- A cost arises from tracking RubyLLM API changes
- Support for providers not covered by RubyLLM may lag
- Mitigated by defining a `Phronomy::LLM::Base` interface to allow future replacements

---

## Decision 2: Manage state as immutable objects

**Situation**: Needed to choose between mutable hashes and immutable objects for Workflow state management.

**Choice**: Adopt a design where `State#merge` immutably returns a new object.

**Rationale**:
- References LangGraph's State design. Makes checkpoint saving and comparison easier
- Prevents bugs where state is unintentionally mutated between nodes
- Makes history tracking and debugging easier
- Easier to avoid race conditions in parallel node execution (future work)

**Trade-offs**:
- Overhead of copying the state object on each update
- Start with shallow merge rather than deep copy to keep initial implementation simple

---

## Decision 3: Use `>>` operator for Chain composition (`|` as alias)

**Situation**: Needed to choose a Ruby composition syntax inspired by LCEL's `|` operator.

**Choice**: Provide `>>` as primary and `|` as alias.

**Rationale**:
- In Ruby, `|` is used idiomatically as a Proc/block `or` operator in some contexts
- `>>` is semantically consistent with Ruby's `Proc#>>` (function composition)
- Provide `|` as an alias for users familiar with Python LangChain's `|`

**Trade-offs**:
- Feels slightly different from Python LangChain's syntax (mitigated by the alias)

---

## Decision 4: Implement the Pregel runtime in-house (no existing gem dependency)

**Situation**: Needed to choose between using an existing Ruby graph gem (rgl, etc.) or implementing the graph execution engine in-house.

**Choice**: Implement a simple version in-house.

**Rationale**:
- Existing Ruby graph libraries (rgl, graph) are specialized for general graph algorithms and do not fit the special requirements of LLM agent execution (stateful nodes, checkpoints, suspend/resume)
- Accurately implementing Pregel concepts (node scheduling, channel-based value propagation) has lower learning and integration cost
- Phase 1–2 implements sequential execution only; parallel execution is deferred to Phase 4+, keeping the initial implementation simple

**Trade-offs**:
- Workflow bugs must be handled in-house
- Complexity of future parallel execution implementation remains

---

## Decision 5: Unify memory scope by thread

**Situation**: Needed to choose between mem0's multi-level memory (user, session, agent) and a simple thread_id-based approach.

**Choice**: Phase 3 implements only `thread_id`-scoped memory. Multi-level is considered for Phase 4+.

**Rationale**:
- For the vast majority of use cases, thread_id (= session ID or conversation ID) is sufficient
- Multi-level memory is for use cases requiring long-term memory across users (personal assistant), which is out of scope initially
- In Rails, using `user.id` as thread_id effectively achieves "user-scoped memory"

**Trade-offs**:
- If a mechanism for memory spanning multiple user sessions is needed, additional implementation will be required later

---

## Decision 6: Security — Tool execution is no-sandbox by default

**Situation**: Needed to decide whether to sandbox tool execution.

**Choice**: No sandbox by default. Use software-level controls combining `requires_approval: true` and Guardrails.

**Rationale**:
- Process sandboxing in Ruby becomes Docker/container-dependent, greatly complicating the framework's installation requirements
- LangGraph and the OpenAI SDK also adopt software-level controls (guardrails + interrupt)
- `requires_approval: true` is required for irreversible operations (delete, send) and must be documented clearly

**Risk mitigation**:
- Tools with `requires_approval: true` trigger a `wait_state` halt in the Workflow before execution
- Shell-execution tools are not provided by the framework; users must implement them explicitly
- Include the OWASP Top 10 checklist in the implementation guidelines

---

## Decision 7: Async execution is sync+Thread only in Phases 1–3

**Situation**: Needed to choose between adopting async-rb (Fiber-based) or sticking with Thread isolation for Ruby's async execution.

**Choice**: Phases 1–3 use synchronous execution as the primary mode; background execution is delegated to Rails ActiveJob. Fiber/async is considered for Phase 4+.

**Rationale**:
- The async-rb ecosystem is still developing compared to Python's asyncio, and there are integration risks with RubyLLM
- In the Rails ecosystem, running background execution via ActiveJob is the standard pattern
- Streaming can be integrated with SSE using Ruby's Fiber/Enumerator without needing async

**Trade-offs**:
- For use cases requiring large numbers of parallel agent executions, the Thread count limit may become a constraint

---

*References: 00_design_philosophy.md, 01_rubyllm_evaluation.md, AI Agent Design Guide 02-scope.md*
