# Phronomy — Public API Design

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
  
  # Human-in-the-Loop interrupt exception
  class Interrupt < Error
    attr_reader :node, :state
    def initialize(node:, state:)
      @node  = node
      @state = state
      super("Graph execution interrupted at node #{node}")
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
    
    # Shortcut: returns a StateGraph
    # @example
    #   graph = Phronomy.graph(MyState) do |g|
    #     g.node(:search) { |state| ... }
    #     g.edge(:search, :answer)
    #   end
    def graph(state_class, &block)
      g = Graph::StateGraph.new(state_class)
      block.call(g) if block
      g
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
  config.default_checkpointer = Phronomy::Checkpointer::InMemory.new
  
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

## 4. Graph API

```ruby
# === State definition ===
class MyWorkflowState
  include Phronomy::Graph::State
  
  field :input,    type: :replace
  field :messages, type: :append,  default: -> { [] }
  field :result,   type: :replace
  field :done,     type: :replace, default: false
end

# === Graph definition (block DSL) ===
graph = Phronomy.graph(MyWorkflowState) do |g|
  g.add_node(:fetch) do |state|
    data = fetch_data(state.input)
    { messages: [{ role: :user, content: data }] }
  end
  
  g.add_node(:process) do |state|
    chat = RubyLLM.chat
    response = chat.ask(state.messages.last[:content])
    { result: response.content, done: true }
  end
  
  g.add_node(:retry_handler) do |state|
    { messages: [{ role: :user, content: "Please retry." }] }
  end
  
  g.add_edge(:fetch, :process)
  g.add_conditional_edges(
    :process,
    ->(state) { state.done ? Phronomy::Graph::StateGraph::END : :retry_handler }
  )
  g.add_edge(:retry_handler, :process)
  
  g.set_entry_point(:fetch)
end

# === Compile ===
checkpointer = Phronomy::Checkpointer::ActiveRecord.new  # Rails environment
compiled = graph.compile(
  checkpointer:,
  interrupt_before: [:process],  # interrupt before :process
  interrupt_after:  []
)

# === Execute ===
result = compiled.invoke(
  { input: "Data to analyze" },
  config: { thread_id: "session_#{user.id}" }
)

# === Human-in-the-Loop ===
begin
  compiled.invoke(input_data, config: { thread_id: "t1" })
rescue Phronomy::Interrupt => e
  puts "Confirmation required before executing #{e.node}"
  puts "Current state: #{e.state.to_h}"
  
  # User confirms
  compiled.resume(thread_id: "t1")
end

# === Streaming (event per node completion) ===
compiled.stream({ input: "..." }) do |event|
  case event[:type]
  when :node_start
    puts "-> Executing #{event[:node]}..."
  when :node_end
    puts "✓ #{event[:node]} completed"
  when :graph_end
    puts "Graph execution complete"
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

# === Use as a Graph node ===
state_graph = Phronomy.graph(SupportState) do |g|
  g.add_node(:greet) { |state| { messages: ["Hello! How can I help you?"] } }
  g.add_node(:support, CustomerSupportAgent.new)  # pass a Runnable directly
  g.add_edge(:greet, :support)
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

## 8. Checkpointer API

```ruby
# === In-memory (development / testing) ===
checkpointer = Phronomy::Checkpointer::InMemory.new

# === ActiveRecord (Rails production) ===
checkpointer = Phronomy::Checkpointer::ActiveRecord.new

# === Manual operations ===
# Save
checkpointer.save("thread_1", state, completed_node: :search)

# Load
checkpoint = checkpointer.load("thread_1")
puts checkpoint.state.to_h
puts checkpoint.completed_node

# List history
history = checkpointer.list("thread_1")

# Delete
checkpointer.delete("thread_1")
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

```ruby
# Gemfile
gem 'phronomy'

# config/initializers/phronomy.rb
Phronomy.configure do |config|
  config.default_model = "claude-3-5-sonnet-20241022"
  config.default_checkpointer = Phronomy::Checkpointer::ActiveRecord.new
  config.default_memory = Phronomy::Memory::ActiveRecordMemory.new
end

# migration (generated by rails generate phronomy:install)
# create_table :phronomy_checkpoints
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
  ├── Phronomy::RecursionLimitError # Graph recursion limit exceeded
  ├── Phronomy::Interrupt           # Human-in-the-Loop suspension
  │     attr_reader :node, :state
  ├── Phronomy::CheckpointError     # Checkpointer failure
  └── Phronomy::ToolError           # Tool execution failure
        attr_reader :tool_name, :cause

# Usage example
begin
  graph.invoke(input, config: { thread_id: "t1" })
rescue Phronomy::Interrupt => e
  # Approval flow
  if approved_by_user?(e)
    graph.resume(thread_id: "t1")
  else
    graph.cancel(thread_id: "t1")
  end
rescue Phronomy::RecursionLimitError
  # Loop detected
  Rails.logger.error "Graph recursion limit exceeded"
rescue Phronomy::ToolError => e
  Rails.logger.error "Tool #{e.tool_name} failed: #{e.cause}"
end
```

---
