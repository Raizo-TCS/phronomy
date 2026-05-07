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
│  ┌─────────┐ ┌─────────┐ ┌──────────┐ ┌─────────┐             │
│  │  Graph  │ │  Agent  │ │  Memory  │ │  Tool   │             │
│  └─────────┘ └─────────┘ └──────────┘ └─────────┘             │
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
| `Graph` | Define and execute agent workflows as a directed graph | LangGraph StateGraph |
| `Agent` | Execution node with tools, instructions, and LLM config | LangGraph ToolNode + Agent |
| `Tool` | Function definition callable from LLM | LangChain Tool |
| `Memory` | Conversation history and context management | LangChain Memory + mem0 |

### 2.2 Execution Infrastructure Components (Required)

| Component | Role | Equivalent |
|---|---|---|
| `Runtime` | Execution engine for Graph | LangGraph Pregel |
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
| `StateStore` | Persistence and resumption of graph execution state | LangGraph Checkpoint |

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
│       ├── state_store/                 # graph state persistence
│       │   ├── base.rb
│       │   ├── in_memory.rb
│       │   ├── active_record.rb
│       │   └── redis.rb
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

**Corresponding components**: `Memory`

- Instructions area: managed by the system prompt inside Graph nodes
- Capability area: managed by `Agent`'s `tools` list
- Knowledge area: injected into nodes from `Memory` retrieval results
- Conversation area: managed by `Memory::WindowMemory` / `SummaryMemory`

### 4.2 Instruction Composition Design (prompt-design)

**Corresponding component**: `Agent`, `Graph`

- Define 5 sections (role instruction, task instruction, environment info, behavior policy, output policy) in Agent's `instructions` or as a node's system prompt
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

**Corresponding components**: `Memory`

- Token limit management: `Memory::SummaryMemory` summarizes old history with LLM
- Priority-based deletion: Remove oldest tool_results first when token limit is exceeded
- Cache efficiency: Fix unchanging instructions at the top (prompt caching support; takes effect when the provider offers this feature)

### 4.6 Processing Cycle and Persistence (cycle-persistence)

**Corresponding components**: `Graph`, `Checkpointer`

- Checkpoint: Save state after each node completes in graph execution
- Suspend/resume: Identify and resume state using `thread_id`
- Fault recovery: Re-execute from the last checkpoint

### 4.7 Agent Composition Selection (agent-composition)

**Corresponding components**: `Graph`, `Agent`

- Single agent: Run `Agent` standalone
- Graph composition: Conditional branching and loops between nodes via `Graph`
- Multi-agent: Agent-as-Tool pattern — wrap sub-agents as `Tool::Base` subclasses and register them on an orchestrator `Agent`

### 4.8 Response and Streaming UX (streaming-ux)

**Corresponding components**: `Graph`

- Propagate RubyLLM streaming at the Graph level
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
Phronomy::Graph
  └─ Phronomy::Runtime::Pregel  (execution engine)
      └─ Phronomy::Graph::Node
          └─ Phronomy::Agent::Base
              └─ RubyLLM::Agent  (or RubyLLM::Chat + Tool)
      └─ Phronomy::Checkpoint::Base
      └─ Phronomy::Memory::Base

Phronomy::Tool
  └─ RubyLLM::Tool  (inheritance or delegation)
```

---
