# Phronomy — Core Component Specifications

## 1. Chain Component

A composable execution pipeline equivalent to LangChain LCEL (LangChain Expression Language).

### 1.1 Runnable Base Interface

The interface implemented by all Chain components.

```ruby
module Phronomy
  module Runnable
    # Synchronous execution
    def invoke(input, config: {})
      raise NotImplementedError
    end
    
    # Streaming execution (with block)
    def stream(input, config: {}, &block)
      # Default: yield invoke result as a single chunk
      result = invoke(input, config:)
      yield result if block_given?
      result
    end
    
    # Batch execution
    def batch(inputs, config: {})
      inputs.map { |input| invoke(input, config:) }
    end
    
    # Pipeline composition: self >> other
    def >>(other)
      Phronomy::Chain::Sequential.new([self, other])
    end
    
    # Pipeline composition: self | other (LCEL style)
    alias_method :|, :>>
  end
end
```

### 1.2 PromptTemplate

```ruby
module Phronomy
  module Chain
    class PromptTemplate
      include Runnable
      
      # @param template [String] ERB template string
      # @param system_template [String, nil] system prompt template
      def initialize(template:, system_template: nil)
        @template = template
        @system_template = system_template
      end
      
      # @param input [Hash] template variables
      # @return [Hash] { system: String, user: String }
      def invoke(input, config: {})
        {
          system: render(@system_template, input),
          user: render(@template, input)
        }.compact
      end
      
      # Create from file
      def self.from_file(path, system_path: nil)
        new(
          template: File.read(path),
          system_template: system_path ? File.read(system_path) : nil
        )
      end
      
      # @param sections [Hash] templates per section
      # { role: "...", task: "...", env: "...", behavior: "...", output: "..." }
      def self.with_sections(**sections)
        template = sections.map { |name, content| "# #{name.to_s.upcase}\n#{content}" }.join("\n\n")
        new(system_template: template)
      end
      
      private
      
      def render(template, vars)
        return nil if template.nil?
        ERB.new(template).result_with_hash(vars)
      end
    end
  end
end
```

### 1.3 LLMChain

```ruby
module Phronomy
  module Chain
    class LLMChain
      include Runnable
      
      # @param model [String] model name
      # @param tools [Array<RubyLLM::Tool>] available tools
      # @param temperature [Float]
      def initialize(model: nil, tools: [], temperature: nil)
        @model = model
        @tools = tools
        @temperature = temperature
      end
      
      # @param input [Hash] { system:, user: } or String
      # @return [String] LLM response text
      def invoke(input, config: {})
        chat = build_chat(config)
        
        case input
        when String
          chat.ask(input)
        when Hash
          chat.with_system(input[:system]) if input[:system]
          chat.ask(input[:user] || input[:message])
        end
        
        chat.last_message.content
      end
      
      def stream(input, config: {}, &block)
        chat = build_chat(config)
        chat.ask(extract_message(input), stream: block)
      end
      
      private
      
      def build_chat(config)
        opts = {}
        opts[:model] = @model || config[:model] if @model || config[:model]
        opts[:temperature] = @temperature if @temperature
        chat = RubyLLM.chat(**opts)
        @tools.each { |t| chat.with_tool(t) }
        chat
      end
    end
  end
end
```

### 1.4 Sequential Chain (Pipeline)

```ruby
module Phronomy
  module Chain
    class Sequential
      include Runnable
      
      def initialize(steps)
        @steps = steps
      end
      
      def invoke(input, config: {})
        @steps.reduce(input) do |current_input, step|
          step.invoke(current_input, config:)
        end
      end
      
      def stream(input, config: {}, &block)
        # Only the last step streams
        intermediate = @steps[0..-2].reduce(input) do |cur, step|
          step.invoke(cur, config:)
        end
        @steps.last.stream(intermediate, config:, &block)
      end
    end
  end
end
```

### 1.5 Usage Example

```ruby
# Basic chain
prompt = Phronomy::Chain::PromptTemplate.new(
  system_template: "You are a helpful assistant.",
  template: "Answer the question: <%= question %>"
)
llm = Phronomy::Chain::LLMChain.new(model: "claude-3-5-sonnet")
parser = Phronomy::OutputParser::JsonParser.new

chain = prompt >> llm >> parser

result = chain.invoke(question: "What is Ruby?")

# Streaming
chain.stream(question: "What is Ruby?") do |chunk|
  print chunk
end
```

---

## 2. Workflow Component

Workflow execution based on a statechart DSL (`Phronomy::Workflow`).
States, transitions, and halt points are declared with a Ruby DSL; the
execution engine is `Phronomy::WorkflowRunner`.

### 2.1 Context Mixin

All context (state) classes must include `Phronomy::WorkflowContext`.
It provides the `field` DSL, immutable `merge`, serialisation helpers, and
internal workflow metadata (`thread_id`, `phase`, `halted?`).

```ruby
class ResearchContext
  include Phronomy::WorkflowContext

  field :query,    type: :replace
  field :research, type: :replace
  field :answer,   type: :replace
  field :messages, type: :append, default: -> { [] }
end
```

Field types:
- `:replace` — overwrites the current value
- `:append`  — array concatenation
- `:merge`   — hash deep merge

### 2.2 Workflow DSL

`Phronomy::Workflow.define` returns a `WorkflowRunner` ready for `invoke`.

```ruby
SEARCH_NODE  = ->(s) { s.merge(research: WebSearchTool.new.execute(query: s.query)) }
ANSWER_NODE  = ->(s) { s.merge(answer: RubyLLM.chat.ask("#{s.query}\n#{s.research}").content) }
REVIEW_NODE  = ->(s) { s.merge(needs_more: s.answer.include?("I don't know")) }

app = Phronomy::Workflow.define(ResearchContext) do
  initial :search

  state :search,  action: SEARCH_NODE
  state :answer,  action: ANSWER_NODE
  state :review,  action: REVIEW_NODE

  # Conditional routing: guard succeeds → loop back; no guard → finish
  after :review, to: :search,       guard: ->(s) { s.needs_more }
  after :review, to: :__finish__
end
```

DSL keywords:

| Keyword | Purpose |
|---|---|
| `initial :node` | Entry point of the workflow |
| `state :name, action: lambda` | Defines an executable state |
| `wait_state :name` | Declares a halt point (no action); execution pauses here |
| `after :from, to: :to` | Unconditional transition |
| `after :from, to: :to, guard: lambda` | Guarded transition (evaluated in order) |
| `event :name, from: :state, to: :target` | Named event for resuming a `wait_state` |

`Phronomy::Workflow::FINISH` (`:__end__`) is the terminal sentinel. Use
`:__finish__` in `after` edges as a shorthand.

### 2.3 WorkflowRunner — Execution

```ruby
# Simple run (no persistence)
result = app.invoke({ query: "Ruby 3.4 features?" })
puts result.answer

# With state persistence (thread_id enables suspend/resume)
Phronomy.configure { |c| c.default_state_store = Phronomy::StateStore::InMemory.new }

result = app.invoke({ query: "Ruby 3.4 features?" }, config: { thread_id: "t1" })
```

Halt and resume using `wait_state`:

```ruby
app = Phronomy::Workflow.define(ApprovalContext) do
  initial :draft
  state     :draft,             action: DRAFT_NODE
  wait_state :awaiting_approval             # execution halts here
  state     :publish,           action: PUBLISH_NODE
  after :draft, to: :awaiting_approval
  after :publish, to: :__finish__
  event :approve, from: :awaiting_approval, to: :publish
end

# First invocation — halts at :awaiting_approval
state = app.invoke({ content: "..." }, config: { thread_id: "t1" })
state.halted?  # => true
state.phase    # => :awaiting_approval

# Human reviews, then resumes
app.send_event(:approve, config: { thread_id: "t1" })
```

### 2.4 Usage Example (multi-step with loop)

```ruby
class ResearchContext
  include Phronomy::WorkflowContext
  field :query,     type: :replace
  field :research,  type: :replace
  field :answer,    type: :replace
  field :needs_more, type: :replace, default: false
end

app = Phronomy::Workflow.define(ResearchContext) do
  initial :search

  state :search,  action: ->(s) { s.merge(research: WebSearchTool.new.execute(query: s.query)) }
  state :answer,  action: ->(s) { s.merge(answer: RubyLLM.chat.ask("#{s.query}: #{s.research}").content) }
  state :review,  action: ->(s) { s.merge(needs_more: s.answer.include?("I don't know")) }

  after :search,  to: :answer
  after :answer,  to: :review
  after :review,  to: :search,      guard: ->(s) { s.needs_more }
  after :review,  to: :__finish__
end

result = app.invoke({ query: "What are the new features in Ruby 3.4?" })
puts result.answer
```

---

## 3. Agent Component

### 3.1 Agent Base Class

```ruby
module Phronomy
  module Agent
    class Base
      include Phronomy::Runnable
      
      class << self
        def model(name = nil)
          if name
            @model = name
          else
            @model || Phronomy.configuration.default_model
          end
        end
        
        def instructions(text = nil, &block)
          if text || block_given?
            @instructions = text || block
          else
            @instructions
          end
        end
        
        def tools(*tool_classes)
          if tool_classes.any?
            @tools = tool_classes
          else
            @tools || []
          end
        end
        
        def temperature(val = nil)
          if val
            @temperature = val
          else
            @temperature
          end
        end
        
        def max_iterations(val = nil)
          if val
            @max_iterations = val
          else
            @max_iterations || 10
          end
        end
      end
      
      def invoke(input, config: {})
        chat = build_chat
        system_msg = build_instructions(input)
        chat.with_system(system_msg) if system_msg
        
        user_message = input.is_a?(String) ? input : input[:message] || input[:query]
        response = chat.ask(user_message)
        
        { output: response.content, messages: chat.messages }
      end
      
      private
      
      def build_chat
        chat = RubyLLM.chat(model: self.class.model)
        self.class.tools.each { |t| chat.with_tool(t) }
        chat
      end
      
      def build_instructions(input)
        instr = self.class.instructions
        case instr
        when String then instr
        when Proc   then instr.call(input)
        when nil    then nil
        end
      end
    end
  end
end

# Usage example
class ResearchAgent < Phronomy::Agent::Base
  model "claude-3-5-sonnet-20241022"
  
  instructions <<~INST
    You are a research assistant. Your job is to find accurate information.
    Always cite your sources and be concise in your responses.
  INST
  
  tools WebSearchTool, ReadFileTool
  temperature 0.3
  max_iterations 10
end

agent = ResearchAgent.new
result = agent.invoke("What are the new features in Ruby 3.3?")
puts result[:output]
```

### 3.2 ReAct Agent (Thought → Action → Observation loop)

Implemented as a Workflow node, driven by WorkflowRunner.

```ruby
module Phronomy
  module Agent
    # ReAct pattern: Reasoning + Acting loop
    # Used as a node inside a Workflow, or standalone
    class ReactAgent < Base
      def invoke(input, config: {})
        max_iter = self.class.max_iterations
        messages = []
        
        max_iter.times do |i|
          response = step(messages, input)
          messages = response[:messages]
          
          # Done when no more tool calls
          break if response[:done]
        end
        
        { output: messages.last&.content, messages: }
      end
      
      private
      
      def step(messages, initial_input)
        chat = build_chat
        messages.each { |m| chat.messages << m }
        
        if messages.empty?
          user_message = extract_message(initial_input)
          response = chat.ask(user_message)
        else
          response = chat.complete
        end
        
        done = chat.last_message.tool_calls.nil? || chat.last_message.tool_calls.empty?
        { messages: chat.messages, done: }
      end
    end
  end
end
```

---

## 4. Memory Component

### 4.1 Memory Interface

```ruby
module Phronomy
  module Memory
    class Base
      # Load conversation history
      # @param thread_id [String]
      # @param options [Hash]
      # @return [Array<RubyLLM::Message>]
      def load_messages(thread_id:, **options)
        raise NotImplementedError
      end
      
      # Save conversation history
      # @param thread_id [String]
      # @param messages [Array<RubyLLM::Message>]
      def save_messages(thread_id:, messages:)
        raise NotImplementedError
      end
      
      # Clear conversation history
      def clear(thread_id:)
        raise NotImplementedError
      end
    end
    
    # Sliding window: retain only the last N turns
    class WindowMemory < Base
      def initialize(k: 10)
        @k = k
        @store = {}
      end
      
      def load_messages(thread_id:, **)
        (@store[thread_id] || []).last(@k * 2)  # k turns = user + assistant = k*2
      end
      
      def save_messages(thread_id:, messages:)
        @store[thread_id] = messages
      end
      
      def clear(thread_id:)
        @store.delete(thread_id)
      end
    end
    
    # Summary compression: compress context by summarizing old messages with LLM
    class SummaryMemory < Base
      def initialize(max_tokens: 4000, summarizer_model: nil)
        @max_tokens = max_tokens
        @summarizer_model = summarizer_model
        @store = {}
        @summaries = {}
      end
      
      def load_messages(thread_id:, **)
        summary = @summaries[thread_id]
        recent = @store[thread_id] || []
        
        if summary
          # Inject summary as a system message at the top
          [summary_message(summary)] + recent
        else
          recent
        end
      end
      
      def save_messages(thread_id:, messages:)
        # Token estimate (simple: character count / 4)
        estimated_tokens = messages.sum { |m| m.content.to_s.length / 4 }
        
        if estimated_tokens > @max_tokens
          compress(thread_id, messages)
        else
          @store[thread_id] = messages
        end
      end
      
      def clear(thread_id:)
        @store.delete(thread_id)
        @summaries.delete(thread_id)
      end
      
      private
      
      def compress(thread_id, messages)
        old_messages = messages[0..-5]  # keep the last 5 messages
        recent_messages = messages[-5..]
        
        # Summarize old messages
        chat = RubyLLM.chat(model: @summarizer_model || "gpt-4o-mini")
        summary_text = chat.ask(
          "Please concisely summarize the following conversation:\n" +
          old_messages.map { |m| "#{m.role}: #{m.content}" }.join("\n")
        ).content
        
        @summaries[thread_id] = summary_text
        @store[thread_id] = recent_messages
      end
      
      def summary_message(text)
        # Struct mimicking RubyLLM::Message
        OpenStruct.new(role: :system, content: "[Conversation Summary]\n#{text}")
      end
    end
  end
end
```

---

## 5. StateStore Component

`StateStore` provides pluggable persistence for workflow thread state.

### 5.1 StateStore Interface

```ruby
module Phronomy
  module StateStore
    class Base
      # Persists the state object. thread_id is read from state.thread_id.
      # @param state [Object] object including Phronomy::WorkflowContext
      def save(state) = raise NotImplementedError

      # Loads the state for the given thread_id.
      # @return [Object, nil]
      def load(thread_id) = raise NotImplementedError

      # Deletes the state for the given thread_id.
      def clear(thread_id) = raise NotImplementedError
    end

    # In-memory implementation (development / testing)
    class InMemory < Base
      def initialize
        @store = {}
        @mutex = Mutex.new
      end

      def save(state)
        @mutex.synchronize { @store[state.thread_id] = serialize(state) }
        self
      end

      def load(thread_id)
        json = @mutex.synchronize { @store[thread_id] }
        json ? deserialize(json) : nil
      end

      def clear(thread_id)
        @mutex.synchronize { @store.delete(thread_id) }
        self
      end
    end
  end
end
```

### 5.2 ActiveRecord Persistence

```ruby
# Migration (generated by rails generate phronomy:install)
# create_table :phronomy_states do |t|
#   t.string :thread_id, null: false, index: { unique: true }
#   t.text   :state_json, null: false
#   t.timestamps
# end

store = Phronomy::StateStore::ActiveRecord.new(
  model_class: PhronmyState
)

# With encryption (ActiveSupport::MessageEncryptor)
enc   = Phronomy::Encryptor::ActiveSupport.new(key: key)
store = Phronomy::StateStore::ActiveRecord.new(
  model_class: PhronmyState,
  encryptor:   enc
)
```

### 5.3 Redis Persistence

```ruby
store = Phronomy::StateStore::Redis.new(
  client: Redis.new(url: ENV["REDIS_URL"]),
  ttl:    3600   # seconds; nil = no expiry
)
```

### 5.4 Configuration

```ruby
Phronomy.configure do |c|
  c.default_state_store = Phronomy::StateStore::InMemory.new
end
```

---

## 6. OutputParser Component

```ruby
module Phronomy
  module OutputParser
    class Base
      include Runnable
      
      def invoke(input, config: {})
        parse(input.is_a?(String) ? input : input.to_s)
      end
      
      def parse(text)
        raise NotImplementedError
      end
    end
    
    class JsonParser < Base
      def parse(text)
        # Also attempt extraction from JSON code blocks
        json_str = text.match(/```(?:json)?\n?(.*?)\n?```/m)&.captures&.first || text
        JSON.parse(json_str, symbolize_names: true)
      rescue JSON::ParserError => e
        raise Phronomy::ParseError, "JSON parse failed: #{e.message}\nInput: #{text}"
      end
    end
    
    class StructuredParser < Base
      def initialize(schema_class)
        @schema_class = schema_class
      end
      
      def parse(text)
        data = JsonParser.new.parse(text)
        @schema_class.new(**data)
      end
    end
  end
end
```

---

## 7. Multi-Agent (Agent-as-Tool Pattern)

Sub-agents are wrapped as `Tool::Base` subclasses so the orchestrator LLM
can invoke them on demand rather than following a hardcoded execution order.

```ruby
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
  tools ResearchTool, WriteTool
  instructions "Use the research tool first, then the write tool to produce a blog post."
end

result = OrchestratorAgent.new.invoke("Write a blog post about Ruby 3.4 new features")
```

For fixed-order multi-agent pipelines, use Workflow states directly:

```ruby
class PipelineContext
  include Phronomy::WorkflowContext
  field :topic,    type: :replace
  field :research, type: :replace
  field :article,  type: :replace
end

app = Phronomy::Workflow.define(PipelineContext) do
  initial :research
  state :research, action: ->(s) { s.merge(research: ResearcherAgent.new.invoke(s.topic)[:output]) }
  state :write,    action: ->(s) { s.merge(article: WriterAgent.new.invoke(s.research)[:output]) }
  after :research, to: :write
  after :write,    to: :__finish__
end
```

---

## 8. Tracer / Observability

```ruby
module Phronomy
  module Tracing
    class Base
      def trace_chain(chain_name, input:, **meta)
        span = start_span(chain_name, input:, **meta)
        result = yield span
        finish_span(span, output: result)
        result
      rescue => e
        finish_span(span, error: e)
        raise
      end
      
      def start_span(name, **attributes)
        raise NotImplementedError
      end
      
      def finish_span(span, output: nil, error: nil)
        raise NotImplementedError
      end
    end
    
    # No-op tracer (default)
    class NullTracer < Base
      def start_span(name, **) = OpenStruct.new(name:)
      def finish_span(span, **) = nil
    end
  end
end
```

---
