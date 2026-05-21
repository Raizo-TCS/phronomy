# Phronomy — Public API Design

> **ARCHIVED — Early Design Draft**
>
> This file reflects the intended API as of the initial design phase and has
> not been updated to track the released implementation. Many examples below
> use APIs that have been renamed, removed, or changed since this document
> was written. For the current public API, see [README.md](../../README.md).
>
> Known divergences (non-exhaustive):
> - `after :state, to: :next` DSL → current DSL: `transition from: :state, to: :next`
> - `event :name, from:, to:` DSL → current DSL: `transition from:, on: :name, to:`
> - `app.send_event(:event, config: { thread_id: })` → current: `app.send_event(state:, event:)`
> - `Phronomy.chain(...)` / `Phronomy.workflow(...)` shortcut methods → removed
> - `config.default_state_store`, `config.default_memory` → not implemented
> - `Phronomy::StateStore::*`, `Phronomy::Memory::WindowMemory` → not in gem
> - `app.stream(input, config:) { |event| }` → not in current public API

## 1. Gem Entry Point

```ruby
# lib/phronomy.rb

require "ruby_llm"
require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.setup

module Phronomy
  class Error < StandardError; end
  class ParseError < Error; end
  class RecursionLimitError < Error; end
  class GuardrailError < Error; end
  class ToolError < Error
    attr_reader :tool_name, :cause
    def initialize(tool_name:, cause:)
      @tool_name = tool_name
      @cause     = cause
      super("Tool #{tool_name} failed: #{cause}")
    end
  end
  
  class << self
    def configuration
      @configuration ||= Configuration.new
    end
    
    def configure
      yield configuration
    end
    
    # Shortcut: returns a Chain
    # @example
    #   Phronomy.chain(model: "gpt-4o") do |c|
    #     c.prompt "Answer: <%= question %>"
    #     c.parse :json
    #   end
    def chain(**opts, &block)
      Chain::Builder.new(**opts).tap { |b| block.call(b) if block }.build
    end
    
    # Shortcut: build a Workflow
    # @example
    #   app = Phronomy::Workflow.define(MyContext) do
    #     initial :fetch
    #     state :fetch, action: FETCH_FN
    #   end
    def workflow(context_class, &block)
      Workflow.define(context_class, &block)
    end
  end
end
```

---

## 2. Configuration API

```ruby
Phronomy.configure do |config|
  # Default model (shared with RubyLLM configuration)
  config.default_model     = "claude-3-5-sonnet-20241022"
  config.default_embedding_model = "text-embedding-3-small"
  
  # Default checkpointer
  config.default_state_store = Phronomy::StateStore::InMemory.new
  
  # Default memory
  config.default_memory = Phronomy::Memory::WindowMemory.new(k: 20)
  
  # Default tracer
  config.tracer = Phronomy::Tracing::NullTracer.new
  
  # Recursion limit
  config.recursion_limit = 25
  
  # Default Human-in-the-Loop behavior
  config.interrupt_handler = nil  # Set a Proc for default handling
end
```

---

## 3. Chain API

```ruby
# === Pattern A: Pipeline via >> operator ===
prompt  = Phronomy::Chain::PromptTemplate.new(
            template: "Please answer the question: <%= question %>",
            system_template: "You are a helpful assistant."
          )
llm     = Phronomy::Chain::LLMChain.new(model: "gpt-4o")
parser  = Phronomy::OutputParser::JsonParser.new

chain = prompt >> llm >> parser
result = chain.invoke(question: "What is Ruby?")

# === Pattern B: Builder DSL ===
chain = Phronomy.chain(model: "claude-3-5-sonnet") do |c|
  c.system "You are an assistant that replies in JSON only."
  c.prompt "Answer the following question in JSON format: <%= question %>"
  c.parse :json
end

# === Pattern C: File-based template ===
prompt = Phronomy::Chain::PromptTemplate.from_file(
  "prompts/research.txt",
  system_path: "prompts/system.txt"
)

# === Streaming ===
chain.stream(question: "What are the new features in Ruby 3.4?") do |chunk|
  print chunk
  $stdout.flush
end

# === Batch execution ===
results = chain.batch([
  { question: "What is Ruby?" },
  { question: "What is Rails?" },
  { question: "What is RubyGems?" }
])
```

---

## 4. Workflow API

> **STALE DSL NOTE**: `after :state, to: :next` and `event :name, from:, to:`
> shown below do not exist in the gem. Use `transition from:, to:` (auto-fire)
> and `transition from:, on: :name, to:` (external event) instead.
> `app.send_event(:event, config:)` should be `app.send_event(state:, event:)`.

```ruby
# === Context definition ===
class MyWorkflowContext
  include Phronomy::WorkflowContext

  field :input,    type: :replace
  field :messages, type: :append,  default: -> { [] }
  field :result,   type: :replace
  field :done,     type: :replace, default: false
end

# === Workflow definition ===
app = Phronomy::Workflow.define(MyWorkflowContext) do
  initial :fetch

  state :fetch, action: ->(s) {
    data = fetch_data(s.input)
    s.merge(messages: [{ role: :user, content: data }])
  }

  state :process, action: ->(s) {
    response = RubyLLM.chat.ask(s.messages.last[:content])
    s.merge(result: response.content, done: true)
  }

  state :retry_handler, action: ->(s) {
    s.merge(messages: [{ role: :user, content: "Please retry." }])
  }

  after :fetch, to: :process
  # Conditional: retry if not done, else finish
  after :process, to: :retry_handler, guard: ->(s) { !s.done }
  after :process, to: :__finish__
  after :retry_handler, to: :process
end

# === Execute ===
Phronomy.configure { |c| c.default_state_store = Phronomy::StateStore::ActiveRecord.new(...) }

result = app.invoke(
  { input: "Data to analyze" },
  config: { thread_id: "session_#{user.id}" }
)

# === Human-in-the-Loop with wait_state ===
class ApprovalContext
  include Phronomy::WorkflowContext
  field :input,  type: :replace
  field :result, type: :replace
end

app = Phronomy::Workflow.define(ApprovalContext) do
  initial :process
  state     :process,             action: PROCESS_NODE
  wait_state :awaiting_approval             # execution halts here
  state     :finalize,            action: FINALIZE_NODE
  after :process,  to: :awaiting_approval
  after :finalize, to: :__finish__
  event :approve, from: :awaiting_approval, to: :finalize
end

# First invocation halts at :awaiting_approval
state = app.invoke({ input: "..." }, config: { thread_id: "t1" })
puts "Halted: #{state.halted?}, phase: #{state.phase}"

# Human approves — resume via send_event
app.send_event(:approve, config: { thread_id: "t1" })

# === Streaming ===
app.stream({ input: "..." }, config: { thread_id: "t1" }) do |event|
  case event[:type]
  when :node_start
    puts "-> Executing #{event[:node]}..."
  when :node_end
    puts "\u2713 #{event[:node]} completed"
  when :graph_end
    puts "Workflow execution complete"
  end
end
```

---

## 5. Agent API

```ruby
# === Declarative definition (class-based) ===
class CustomerSupportAgent < Phronomy::Agent::Base
  model "claude-3-5-sonnet-20241022"
  temperature 0.5
  max_iterations 15
  
  instructions <<~INST
    You are a friendly customer support agent.
    Please resolve user issues politely.
    If you cannot resolve the issue, use the escalation tool.
  INST
  
  tools SearchKnowledgeBase,
        CreateTicket,
        EscalateToHuman
end

# === Usage ===
agent = CustomerSupportAgent.new
result = agent.invoke("What is the status of order #12345?")
puts result[:output]

# === Use as a Workflow state action ===
class SupportContext
  include Phronomy::WorkflowContext
  field :messages, type: :append, default: -> { [] }
end

app = Phronomy::Workflow.define(SupportContext) do
  initial :greet
  state :greet,   action: ->(s) { s.merge(messages: ["Hello! How can I help you?"]) }
  state :support, action: ->(s) { s.merge(messages: [CustomerSupportAgent.new.invoke(s.messages.last)[:output]]) }
  after :greet,   to: :support
  after :support, to: :__finish__
end
```

---

## 6. Tool API

```ruby
# === Tool definition (inherits from RubyLLM::Tool) ===
class SearchKnowledgeBase < Phronomy::Tool::Base
  description "Searches the internal knowledge base"
  
  param :query,    type: :string,  desc: "Search query"
  param :limit,    type: :integer, desc: "Maximum results", required: false
  param :category, type: :string,  desc: "Category filter", required: false
  
  # Permission scope definition (optional)
  scope :read_only
  
  # Default behavior on failure
  on_error :return_empty
  
  def execute(query:, limit: 5, category: nil)
    results = KnowledgeBase.search(query:, limit:, category:)
    results.map { |r| { title: r.title, content: r.body } }
  end
end

# === Tool requiring human approval ===
class DeleteCustomerData < Phronomy::Tool::Base
  description "Deletes customer data (requires approval)"
  
  param :customer_id, type: :string, desc: "Customer ID"
  
  # This tool requires human approval before execution
  requires_approval true
  
  def execute(customer_id:)
    Customer.find(customer_id).destroy
    { success: true, message: "Customer data deleted" }
  end
end

# === MCP tool (via external MCP server) ===
mcp_tool = Phronomy::Tool::McpTool.from_server(
  "stdio://path/to/mcp-server",
  tool_name: "search_web"
)
```

---

## 7. Memory API

```ruby
# === Basic usage ===
memory = Phronomy::Memory::WindowMemory.new(k: 20)
memory.save_messages(
  thread_id: "user_123",
  messages: chat.messages
)
past_messages = memory.load_messages(thread_id: "user_123")

# === Integration with Agent / Chain ===
agent = MyAgent.new
result = agent.invoke(
  "A follow-up question",
  config: {
    thread_id: "user_123",
    memory: Phronomy::Memory::SummaryMemory.new(max_tokens: 4000)
  }
)

# === Rails ActiveRecord integration ===
# config/initializers/phronomy.rb
Phronomy.configure do |c|
  c.default_memory = Phronomy::Memory::ActiveRecordMemory.new
end
```

---

## 8. StateStore API

```ruby
# === In-memory (development / testing) ===
Phronomy.configure { |c| c.default_state_store = Phronomy::StateStore::InMemory.new }

# === ActiveRecord (Rails production) ===
Phronomy.configure { |c| c.default_state_store = Phronomy::StateStore::ActiveRecord.new(model_class: PhronmyState) }

# === Redis ===
Phronomy.configure { |c| c.default_state_store = Phronomy::StateStore::Redis.new(client: Redis.new, ttl: 3600) }

# === Manual operations ===
store = Phronomy::StateStore::InMemory.new
store.save(state)          # state.thread_id is used as key
state = store.load("t1")
store.clear("t1")
```

---

## 9. Multi-Agent (Agent-as-Tool Pattern)

```ruby
# Sub-agents wrapped as tools so the orchestrator LLM can call them on demand.

class ResearchTool < Phronomy::Tool::Base
  description "Research a topic and return key findings as bullet points."
  param :topic, type: :string, desc: "The topic to research"

  def execute(topic:)
    ResearcherAgent.new.invoke(topic)[:output]
  end
end

class WriteTool < Phronomy::Tool::Base
  description "Write a technical blog post given research notes and a writing brief."
  param :instructions, type: :string, desc: "Writing brief including research notes"

  def execute(instructions:)
    WriterAgent.new.invoke(instructions)[:output]
  end
end

class OrchestratorAgent < Phronomy::Agent::Base
  model "claude-3-5-sonnet-20241022"
  tools ResearchTool, WriteTool
  instructions "Produce a high-quality blog post. Use research tool first, then write tool."
end

result = OrchestratorAgent.new.invoke("Write a blog post about Ruby 3.4 new features")
puts result[:output]
```

---

## 10. Rails Integration API

> **STALE NOTE**: `config.default_state_store`, `config.default_memory`,
> `acts_as_phronomy_thread`, and `agent.stream(...)` shown below are not
> implemented in the current gem. See README.md for the Rails example that
> ships with phronomy-examples.

```ruby
# Gemfile
gem 'phronomy'

# config/initializers/phronomy.rb
Phronomy.configure do |config|
  config.default_model = "claude-3-5-sonnet-20241022"
  config.default_state_store = Phronomy::StateStore::ActiveRecord.new(model_class: PhronmyState)
  config.default_memory = Phronomy::Memory::ActiveRecordMemory.new
end

# migration (generated by rails generate phronomy:install)
# create_table :phronomy_states
# create_table :phronomy_messages

# ActiveRecord model integration
class Conversation < ApplicationRecord
  acts_as_phronomy_thread  # use the record's id as thread_id
end

# Usage in a controller
class ChatController < ApplicationController
  def create
    conversation = Conversation.find(params[:id])
    agent = CustomerSupportAgent.new
    
    result = agent.invoke(
      params[:message],
      config: { thread_id: conversation.id.to_s }
    )
    
    render json: { response: result[:output] }
  end
end

# Streaming with ActionCable
class ChatChannel < ApplicationCable::Channel
  def receive(data)
    agent = CustomerSupportAgent.new
    
    agent.stream(data["message"], config: { thread_id: current_user.id.to_s }) do |chunk|
      ActionCable.server.broadcast("chat_#{current_user.id}", { chunk: })
    end
  end
end
```

---

## 11. Error Handling

```ruby
# Standard exception hierarchy
Phronomy::Error
  ├── Phronomy::ParseError          # OutputParser failure
  ├── Phronomy::RecursionLimitError # Workflow recursion limit exceeded
  ├── Phronomy::GuardrailError      # Guardrail violation
  └── Phronomy::ToolError           # Tool execution failure
        attr_reader :tool_name, :cause

# Halt and resume (no exception raised — use wait_state + send_event)
app = Phronomy::Workflow.define(MyContext) do
  # ...
  wait_state :awaiting_approval
  event :approve, from: :awaiting_approval, to: :next_step
end

state = app.invoke(input, config: { thread_id: "t1" })
if state.halted?
  # User reviews state, then resumes
  app.send_event(:approve, config: { thread_id: "t1" })
end

rescue Phronomy::RecursionLimitError
  Rails.logger.error "Workflow recursion limit exceeded"
rescue Phronomy::ToolError => e
  Rails.logger.error "Tool #{e.tool_name} failed: #{e.cause}"
end
```

---
