> **HISTORICAL / non-normative snapshot**
>
> Preserved as design history. This document does not define current Phronomy
> architecture or public compatibility. Start at
> [docs/architecture.md](../../../architecture.md) and the
> [ADR index](../../../decisions/README.md).

# RubyLLM Evaluation Report — Adoption Assessment as Phronomy Backend

## 1. Overview

This document evaluates the pros and cons of adopting the `ruby_llm` gem as the LLM abstraction layer for Phronomy. LangChain Core (Python) and LiteLLM (Python) are referenced as comparison targets.

---

## 2. Current Capabilities of RubyLLM

Features provided by RubyLLM as of the current state (May 2026).

| Feature | Status | Notes |
|---|---|---|
| Multi-provider support | ✅ | OpenAI, Anthropic, Gemini, Bedrock, Azure, Ollama, Mistral, DeepSeek, etc. 13+ |
| Chat API | ✅ | `RubyLLM.chat` |
| Tool calling (Function Calling) | ✅ | `RubyLLM::Tool` DSL |
| Agent DSL | ✅ | `RubyLLM::Agent` class-based |
| Streaming | ✅ | SSE-based |
| Embeddings | ✅ | `RubyLLM.embed` |
| Image generation | ✅ | `RubyLLM.paint` |
| Audio transcription | ✅ | `RubyLLM.transcribe` |
| Moderation | ✅ | `RubyLLM.moderate` |
| Structured output | ✅ | Via `ruby_llm-schema` gem |
| Extended Thinking | ✅ | `thinking.rb` |
| Rails / ActiveRecord integration | ✅ | `acts_as_chat`, `acts_as_message` |
| Rails generators | ✅ | install, agent, tool, chat UI, etc. |
| Model registry | ✅ | 800+ models, capability/pricing information |
| Async support | ✅ | Asynchronous execution |
| Multimodal | ✅ | Image, audio, PDF attachments |

RubyLLM covers nearly all the functionality needed as an "LLM abstraction layer" and has rich Rails integration.

---

## 3. Evaluation from the Phronomy Perspective

### 3.1 Advantages

#### (A) High completeness as an LLM abstraction layer

Provider differences (API specs, authentication, streaming, tool calling formats) are already handled, so Phronomy development does not need to build the LLM communication layer from scratch. Support for 13+ providers is extremely important in production.

#### (B) Tool definitions are easy to use as a Ruby DSL

```ruby
class WebSearch < RubyLLM::Tool
  description "Searches the web for information"
  
  param :query, type: :string, desc: "The search query"
  param :max_results, type: :integer, desc: "Maximum results", required: false
  
  def execute(query:, max_results: 5)
    # implementation
  end
end
```

Phronomy's Tool component can be designed to inherit and extend this DSL.

#### (C) Affinity with Rails / ActiveRecord

`acts_as_chat` and `acts_as_message` allow DB persistence of conversation history directly. Useful as the foundation for Phronomy's `StateStore::ActiveRecord` implementation.

#### (D) Built-in model registry

Model capabilities (whether function calling is supported, vision support, etc.) can be retrieved from the registry. Useful when Phronomy makes "dynamic decisions based on the capabilities of the model in use."

#### (E) Minimal dependencies with low security risk

Main dependencies are only `faraday` (HTTP) and `event_stream_parser` (SSE). Compared to frameworks with many dependencies, the security supply-chain risk is small.

#### (F) Commitment to the Ruby ecosystem

The combination of Rails generators, `railtie.rb`, and `acts_as_*` DSL shows strong commitment to the Ruby/Rails community. Phronomy can inherit the same culture.

#### (G) Streaming support is built-in

SSE-based streaming is implemented as standard, so Phronomy's streaming UX features (progressive token display) can be used at no additional cost.

---

### 3.2 Disadvantages and Limitations

#### (A) Agent orchestration features are too basic

`RubyLLM::Agent` can declare model/instructions/tools/temperature to run a single agent, but does not support:

- **State graph**: Workflow execution defining multiple steps with states and transitions
- **Checkpoint**: Suspend/resume of graph state (ActiveRecord persistence exists, but not AgentLoop state saving)
- **Multi-agent coordination**: Agent-to-agent handoff / delegation
- **Human-in-the-Loop**: Mechanism to pause execution and wait for user approval

→ **Mitigation**: Phronomy implements these as an upper layer. RubyLLM's Agent is positioned internally as an "execution node for LLM calls."

#### (B) No context management or conversation compression

Chat accumulates conversation history, but there is no context compression, summarization, or deletion policy against token limits. Context window overflow occurs in long agent loops.

→ **Mitigation**: Phronomy's `Memory` / `ContextManager` components provide conversation compression, summaries, and sliding windows.

#### (C) No chain composition (pipeline) mechanism

There is no mechanism for chain composition via `|` operator like LCEL (LangChain Expression Language), or for defining pipelines of prompt template → LLM → output parser.

→ **Mitigation**: Phronomy's `Chain` component provides pipeline composition via `>>` operator (or `|`).

#### (D) Limited output parsers

Structured output via `ruby_llm-schema` exists, but there is no flexible output formatting/transformation layer equivalent to LangChain's diverse `OutputParser` (JSON, XML, Markdown, Pydantic, etc.).

→ **Mitigation**: Phronomy's `OutputParser` component provides various parsers.

#### (E) No observability or tracing

No execution trace collection or output to LangSmith or Langfuse. Lacks the debugging/monitoring infrastructure needed in production.

→ **Mitigation**: Phronomy's `Tracer` component provides OpenTelemetry-based tracing.

#### (F) Community and ecosystem are small compared to Python

No massive plugin ecosystem or integration library collection like LangChain or CrewAI. Third-party Tool/Integration beyond provider integration is limited.

→ **Mitigation**: Phronomy implements MCP (Model Context Protocol) support so that Python's MCP tool ecosystem can be used from Ruby.

#### (G) No Pregel/Workflow runtime

There is no Ruby implementation equivalent to LangGraph's core Pregel computation model (workflow state scheduling, parallel execution, channel-based value propagation).

→ **Mitigation**: Phronomy implements a lightweight Pregel-like graph runtime (simple version initially, extended later).

#### (H) Integration with Ruby's async processing ecosystem

Ruby's async processing (Async gem, Fiber-based) is still developing compared to Python's asyncio. Async execution design in Phronomy requires careful judgment.

→ **Mitigation**: Support synchronous execution fully first, then provide async incrementally with Fiber/Thread.

---

## 4. Adoption Decision

### 4.1 Reasons for Adopting (Recommended)

RubyLLM covers all necessary functionality as an "LLM abstraction layer" and has made significant investment in the Ruby/Rails ecosystem. By implementing the missing "framework layer" (graph execution, chain composition, memory management) as an upper layer, a collaborative design that leverages each other's strengths is possible.

### 4.2 Alternatives if Not Adopted

| Alternative | Issues |
|---|---|
| Implement from scratch with direct Faraday | Enormous implementation cost for provider support |
| Langchainrb gem | Maintenance status unstable, limited features |
| Call Python LangChain via Ruby FFI | Loses Ruby idiom, deployment complexity |
| OpenAI Ruby gem alone | Locked to OpenAI, no multi-provider |

### 4.3 Adoption Form

- **Core dependency**: Require `ruby_llm` as a mandatory dependency
- **Extension point**: Define a `Phronomy::LLM::Base` interface so adapters for non-RubyLLM clients can be connected in the future
- **Tool inheritance**: `Phronomy::Tool` inherits (or delegates to) `RubyLLM::Tool` to provide additional functionality
- **Agent usage**: Use `RubyLLM::Agent` internally while wrapping it as a Phronomy Workflow node

---

## 5. Version Requirements

```ruby
# Gemfile
gem 'ruby_llm', '>= 1.3'   # After Tool DSL, Agent, Streaming, Rails integration stabilized
```

---
