# Ruby AI Agent Framework — Design Philosophy and Goals

## 1. Overview

This framework (working name: **Phronomy**) is an AI agent construction framework for the Ruby ecosystem that provides functionality equivalent to LangChain and LangGraph. It leverages the `ruby_llm` gem for LLM communication and aims to deliver chain composition, state-graph execution, memory management, and multi-agent coordination through a Ruby-idiomatic DSL.

---

## 2. Problems We Are Solving

Currently, the Ruby/Rails ecosystem lacks a framework that provides the following features in an integrated way.

| Feature | Python Options | Ruby Status |
|---|---|---|
| LLM Abstraction | LangChain Core, LiteLLM | RubyLLM (available) |
| Chain Composition | LangChain LCEL | **none** |
| State Graph Execution | LangGraph StateGraph | **none** |
| Checkpoint Persistence | LangGraph Checkpoint | **none** |
| Multi-agent Coordination | CrewAI / LangGraph | **none** |
| Conversation Memory | LangChain Memory, mem0 | partial (RubyLLM AR) |
| Human-in-the-Loop | LangGraph interrupt | **none** |
| Observability / Tracing | LangSmith, Langfuse | **none** |

---

## 3. Design Principles

### 3.1 Ruby-Idiom First

Rather than a direct translation of Python frameworks, this framework is redesigned to align with Ruby's idiomatic expressions, DSL culture, and type system. Instead of Pythonic `@decorator` patterns, it uses Ruby's `include`, `define_method`, blocks/Procs, and module mixins to provide equivalent functionality.

### 3.2 Progressive Adoption

- **Level 0**: Simple chat and tool calls where RubyLLM alone is sufficient
- **Level 1**: Compose prompt → LLM → parser pipelines with Phronomy's Chain
- **Level 2**: Define multi-step workflows and agent loops with Graph
- **Level 3**: Add state persistence and suspend/resume with Memory/Checkpointer
- **Level 4**: Coordinate multiple agents with Multi-agent

Each level can be adopted independently, so there is no need to introduce the entire framework at once.

### 3.3 Rails Integration as First Class

Like RubyLLM, Phronomy ships with a `railtie` and provides `acts_as_*` DSL for ActiveRecord model integration. The cost of embedding it into a Rails app is minimized.

### 3.4 Replaceable LLM Abstraction Layer

RubyLLM serves as the standard backend, but an interface is defined so that other LLM clients can be plugged in as extension points.

### 3.5 Minimal Dependencies

The core depends only on RubyLLM and the Ruby standard library. Optional features (Redis checkpointer, vector search, Observer integration) are separated as optional gems.

---

## 4. Scope

### 4.1 What This Framework Provides

- **Chain**: A composable pipeline of prompt template → LLM → output parser
- **Agent**: A reusable execution unit with tools, instructions, and LLM settings
- **Graph**: A state-based agent workflow defined as a directed graph
- **Memory**: Conversation history management (short-term and long-term), context window management
- **Checkpointer**: Persistence, suspension, and resumption of graph execution state
- **Tool**: Function definitions callable from LLM (extends RubyLLM's Tool)
- **Guardrail**: Input/output validation and constraints
- **Tracer**: Execution trace collection and output

### 4.2 What This Framework Does Not Provide (Out of Scope)

- LLM provider API implementations (delegated to RubyLLM)
- Vector DB implementations (provided externally via adapters)
- Frontend UI / Chat UI
- RAG index construction pipelines (usable as tools)
- Model fine-tuning

---

## 5. Referenced OSS and Their Role

| OSS | Concepts Referenced | Corresponding Component |
|---|---|---|
| LangChain Core | Runnable / LCEL chain composition | Chain component |
| LangGraph | StateGraph, Pregel execution, Checkpoint | Graph / Checkpointer components |
| CrewAI | Agent role-separation model (Crew/Task dropped; Agent-as-Tool adopted instead) | Agent component |
| OpenAI Agents SDK | Handoff, Guardrail, Tracing | Handoff / Guardrail / Tracer |
| RubyLLM | LLM abstraction, Tool, Rails integration | Used as the LLM abstraction layer |
| mem0 | Multi-level memory design | Reference for Memory component design |

---

## 6. Target Users

| User Group | Use Case |
|---|---|
| Rails developers | Add AI agent features to existing Rails applications |
| Ruby backend engineers | Automate AI workflows in batch processing or API services |
| AI application developers | Build LLM applications in Ruby as a Python alternative |

---

## 7. Name Candidates

| Candidate | Origin / Intent |
|---|---|
| **Phronomy** | Agent + workflow/graph flow. Intuitive |
| **Raix** | Ruby AI eXecution. Short and memorable |
| **Flowable** | Emphasizes flow/graph composition. Ruby-style `-able` |
| **Kenna** | Ruby-inspired name |

This document uses **Phronomy** as the working name.

---

*Reference documents: AI Agent Design Guide Part I (00-preface, 01-overview, 02-scope)*
