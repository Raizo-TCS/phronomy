# Phronomy — Architecture Overview

## 1. Three-Layer Architecture

Phronomy follows the "three-layer model" from the AI Agent Design Guide.

```
┌─────────────────────────────────────────────────────────────────┐
│                       Application Layer                          │
│   Agents, workflows, and Rails apps implemented by the user      │
└─────────────────────────────┬───────────────────────────────────┘
                              │ uses
┌─────────────────────────────▼───────────────────────────────────┐
│                   Framework Layer (Phronomy)                     │
│                                                                  │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────┐ ┌─────────┐  │
│  │  Chain  │ │  Graph  │ │  Agent  │ │  Memory  │ │  Tool   │  │
│  └─────────┘ └─────────┘ └─────────┘ └──────────┘ └─────────┘  │
│  ┌──────────────┐ ┌──────────┐ ┌────────────┐ ┌─────────────┐  │
│  │ Checkpointer │ │Guardrail │ │   Tracer   │ │ OutputParser│  │
│  └──────────────┘ └──────────┘ └────────────┘ └─────────────┘  │
└─────────────────────────────┬───────────────────────────────────┘
                              │ uses
┌─────────────────────────────▼───────────────────────────────────┐
│                   LLM Abstraction Layer (RubyLLM)                │
│                                                                  │
│  Chat / Tool / Agent / Embedding / Streaming / Rails integration │
│  Providers: OpenAI / Anthropic / Gemini / Ollama / ...          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Component Structure

### 2.1 Core Components (Required)

| Component | Role | LangGraph/LangChain Equivalent |
|---|---|---|
| `Chain` | Pipeline composition of prompt → LLM → parser | LCEL Runnable |
| `Graph` | Define and execute agent workflows as a directed graph | LangGraph StateGraph |
| `Agent` | Execution node with tools, instructions, and LLM config | LangGraph ToolNode + Agent |
| `Task` | Task definition for an agent (description, expected output) | CrewAI Task |
| `Tool` | Function definition callable from LLM | LangChain Tool |
| `Memory` | Conversation history and context management | LangChain Memory + mem0 |

### 2.2 Execution Infrastructure Components (Required)

| Component | Role | Equivalent |
|---|---|---|
| `Runtime` | Execution engine for Graph/Chain | LangGraph Pregel |
| `State` | State definition and updates for graph execution | LangGraph State |
| `Channel` | Value propagation definition between nodes | LangGraph Channel |
| `Checkpointer` | Persistence, suspension, and resumption of execution state | LangGraph Checkpoint |

### 2.3 Extension Components (Optional gems)

| Component | Role | Gem Name |
|---|---|---|
| `Guardrail` | Input/output validation and constraints | `phronomy-guardrails` |
| `Tracer` | Execution trace collection and output | `phronomy-tracing` |
| `OutputParser` | Conversion to various output formats | Included in core |
| `EmbeddingStore` | Vector search / RAG | `phronomy-rag` |
| `Crew` | Multi-agent coordination | Included in core (Level 4) |

---

## 3. Directory Structure (Expected)

```
phronomy/
├── lib/
│   ├── phronomy.rb                    # gem entry point
│   └── phronomy/
│       ├── version.rb
│       ├── configuration.rb             # global configuration
│       │
│       ├── chain/                       # Chain component
│       │   ├── base.rb                  # Runnable base
│       │   ├── prompt_template.rb       # prompt template
│       │   ├── llm_chain.rb             # LLM call chain
│       │   └── sequential_chain.rb      # sequential chain
│       │
│       ├── graph/                       # Graph component
│       │   ├── state_graph.rb           # graph definition API
│       │   ├── node.rb                  # node base
│       │   ├── edge.rb                  # edge definition
│       │   ├── channel.rb               # channel value propagation
│       │   └── conditional_edge.rb      # conditional edges
│       │
│       ├── runtime/                     # execution engine
│       │   ├── pregel.rb                # Pregel-like graph execution
│       │   ├── executor.rb              # node execution
│       │   └── event_bus.rb             # event notifications
│       │
│       ├── agent/                       # Agent component
│       │   ├── base.rb                  # Agent base class
│       │   ├── react_agent.rb           # ReAct pattern
│       │   └── tool_calling_agent.rb    # Tool Calling pattern
│       │
│       ├── task/                        # Task component
│       │   └── base.rb
│       │
│       ├── tool/                        # Tool component
│       │   ├── base.rb                  # RubyLLM::Tool extension
│       │   └── mcp_tool.rb              # MCP protocol support
│       │
│       ├── memory/                      # Memory component
│       │   ├── base.rb                  # Memory interface
│       │   ├── in_memory.rb             # in-memory implementation
│       │   ├── window_memory.rb         # sliding window
│       │   ├── summary_memory.rb        # summary compression
│       │   └── active_record_memory.rb  # ActiveRecord persistence
│       │
│       ├── checkpoint/                  # Checkpointer component
│       │   ├── base.rb                  # Checkpointer interface
│       │   ├── in_memory.rb             # in-memory (for development)
│       │   ├── active_record.rb         # ActiveRecord persistence
│       │   └── redis.rb                 # Redis persistence (optional)
│       │
│       ├── output_parser/               # output parsers
│       │   ├── base.rb
│       │   ├── json_parser.rb
│       │   └── structured_parser.rb
│       │
│       ├── guardrail/                   # Guardrail (optional)
│       │   ├── base.rb
│       │   ├── input_guardrail.rb
│       │   └── output_guardrail.rb
│       │
│       ├── tracing/                     # Tracer (optional)
│       │   ├── base.rb
│       │   └── null_tracer.rb
│       │
│       ├── crew/                        # multi-agent coordination
│       │   ├── crew.rb
│       │   └── handoff.rb
│       │
│       ├── active_record/               # Rails / ActiveRecord integration
│       │   ├── acts_as.rb
│       │   └── checkpoint_record.rb
│       │
│       └── railtie.rb                   # Rails integration
│
├── spec/                                # RSpec tests
├── generators/                          # Rails generators
├── phronomy.gemspec
├── Gemfile
└── Rakefile
```

---

## 4. Design Decisions and Approach

Phronomy's approach to the 11 design topics from the AI Agent Design Guide.

### 4.1 Information Structure Design (info-structure)

**Corresponding components**: `Chain::PromptTemplate`, `Memory`

- Instructions area: managed by `PromptTemplate`'s `system_template`
- Capability area: managed by `Agent`'s `tools` list
- Knowledge area: injected into `Chain` from `Memory` retrieval results
- Conversation area: managed by `Memory::WindowMemory` / `SummaryMemory`

### 4.2 Instruction Composition Design (prompt-design)

**Corresponding component**: `Chain::PromptTemplate`

- Define 5 sections (role instruction, task instruction, environment info, behavior policy, output policy) as `PromptTemplate` sections
- Support both static templates (YAML/ERB file-based) and dynamic composition (block-based)
- Provider differences are delegated to RubyLLM's Provider layer

### 4.3 Tool Design and Permission Boundaries (tools)

**Corresponding components**: `Tool`, `Guardrail`

- `Phronomy::Tool` extends `RubyLLM::Tool` to add permission scopes, execution policies, and HumanApproval hooks
- Guardrail validates before/after dangerous tool executions

### 4.4 Knowledge and Memory Strategy (knowledge-memory)

**Corresponding components**: `Memory`, `EmbeddingStore`

- Short-term: `Memory::WindowMemory` (retain last N turns)
- Long-term: `Memory::ActiveRecordMemory` (DB persistence)
- Semantic: `EmbeddingStore` for RAG (optional)

### 4.5 Context Management Implementation (context-management)

**Corresponding components**: `Memory`, `Chain`

- Token limit management: `Memory::SummaryMemory` summarizes old history with LLM
- Priority-based deletion: Remove oldest tool_results first when token limit is exceeded
- Cache efficiency: Fix unchanging instructions at the top (Anthropic prompt caching support)

### 4.6 Processing Cycle and Persistence (cycle-persistence)

**Corresponding components**: `Graph`, `Checkpointer`

- Checkpoint: Save state after each node completes in graph execution
- Suspend/resume: Identify and resume state using `thread_id`
- Fault recovery: Re-execute from the last checkpoint

### 4.7 Agent Composition Selection (agent-composition)

**Corresponding components**: `Graph`, `Crew`

- Single agent: Run `Agent` standalone
- Graph composition: Conditional branching and loops between nodes via `Graph`
- Multi-agent: Agent coordination via `Crew` (Handoff pattern)

### 4.8 Response and Streaming UX (streaming-ux)

**Corresponding components**: `Chain`, `Graph`

- Propagate RubyLLM streaming at the Chain/Graph level
- Integration with Rails ActionController::Live / ActionCable

### 4.9 Human Intervention Design (human-in-loop)

**Corresponding components**: `Graph`, `Tool::HumanApproval`

- `Graph` allows setting `interrupt` before/after node execution
- When `interrupt` occurs: Save state to Checkpointer and wait for human input
- Resume: Continue with `graph.resume(thread_id:, input:)`

### 4.10 External Integration and Protocols (external-integration)

**Corresponding component**: `Tool::McpTool`

- Connect to MCP (Model Context Protocol) servers
- Use external tool ecosystem from Ruby via MCP
- Webhook/event-triggered execution is the application layer's responsibility

### 4.11 Validation, Observability, and Evaluation (validation)

**Corresponding components**: `Tracer`, `Guardrail`

- `Tracer::NullTracer` as default (no-op)
- OpenTelemetry / Langfuse / LangSmith adapters (optional gems)
- Guardrail for automatic output quality validation

---

## 5. Dependency Diagram

```
Phronomy::Chain
  └─ Phronomy::PromptTemplate
  └─ RubyLLM::Chat  (LLM call)
  └─ Phronomy::OutputParser

Phronomy::Graph
  └─ Phronomy::Runtime::Pregel  (execution engine)
      └─ Phronomy::Graph::Node
          └─ Phronomy::Agent::Base
              └─ RubyLLM::Agent  (or RubyLLM::Chat + Tool)
          └─ Phronomy::Chain
      └─ Phronomy::Checkpoint::Base
      └─ Phronomy::Memory::Base

Phronomy::Tool
  └─ RubyLLM::Tool  (inheritance or delegation)
```

---
