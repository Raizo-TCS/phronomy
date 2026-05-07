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

## 2. Graph Component

State graph-based agent workflow definition and execution, equivalent to LangGraph's StateGraph.

### 2.1 State Definition

```ruby
module Phronomy
  module Graph
    # Module for defining graph state
    # Include in a class to use
    module State
      def self.included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@fields, {})
      end
      
      module ClassMethods
        # Field definition
        # @param name [Symbol]
        # @param type [Symbol] :replace, :append, :merge
        # @param default [Object, Proc]
        def field(name, type: :replace, default: nil)
          @fields[name] = { type:, default: }
          attr_accessor name
        end
        
        def fields
          @fields
        end
      end
      
      def initialize(**attrs)
        self.class.fields.each do |name, config|
          default = config[:default].is_a?(Proc) ? config[:default].call : config[:default]
          send(:"#{name}=", attrs.fetch(name, default))
        end
      end
      
      # Immutably update state (returns a new object)
      def merge(updates)
        new_attrs = {}
        self.class.fields.each_key do |name|
          field_config = self.class.fields[name]
          if updates.key?(name)
            new_attrs[name] = case field_config[:type]
                              when :append
                                Array(send(name)) + Array(updates[name])
                              when :merge
                                (send(name) || {}).merge(updates[name])
                              else
                                updates[name]
                              end
          else
            new_attrs[name] = send(name)
          end
        end
        self.class.new(**new_attrs)
      end
      
      def to_h
        self.class.fields.keys.each_with_object({}) do |name, h|
          h[name] = send(name)
        end
      end
    end
  end
end

# Usage example
class AgentState
  include Phronomy::Graph::State
  
  field :messages, type: :append, default: -> { [] }
  field :query, type: :replace
  field :result, type: :replace
  field :error, type: :replace
  field :metadata, type: :merge, default: -> { {} }
end
```

### 2.2 StateGraph

```ruby
module Phronomy
  module Graph
    class StateGraph
      START = :__start__
      END   = :__end__
      
      attr_reader :nodes, :edges, :entry_point
      
      def initialize(state_class)
        @state_class = state_class
        @nodes = {}
        @edges = {}          # { from_node => to_node_or_array }
        @conditional_edges = {}  # { from_node => lambda }
        @entry_point = nil
      end
      
      # Add a node
      # @param name [Symbol]
      # @param callable [#call, nil] node execution logic (block also accepted)
      def add_node(name, callable = nil, &block)
        @nodes[name] = callable || block
        self
      end
      
      # Add an edge
      # @param from [Symbol]
      # @param to [Symbol]
      def add_edge(from, to)
        @edges[from] ||= []
        @edges[from] << to
        self
      end
      
      # Add a conditional edge
      # @param from [Symbol]
      # @param condition [Proc] receives state and returns the next node name
      # @param mapping [Hash, nil] return value → node name mapping (optional)
      def add_conditional_edges(from, condition, mapping = nil)
        @conditional_edges[from] = { condition:, mapping: }
        self
      end
      
      # Set the entry point
      def set_entry_point(node_name)
        @entry_point = node_name
        self
      end
      
      # Compile (convert to an executable graph)
      # @param checkpointer [Checkpointer::Base, nil]
      # @param interrupt_before [Array<Symbol>]
      # @param interrupt_after [Array<Symbol>]
      def compile(checkpointer: nil, interrupt_before: [], interrupt_after: [])
        CompiledGraph.new(
          state_class: @state_class,
          nodes: @nodes,
          edges: @edges,
          conditional_edges: @conditional_edges,
          entry_point: @entry_point || @nodes.keys.first,
          checkpointer:,
          interrupt_before:,
          interrupt_after:
        )
      end
    end
  end
end
```

### 2.3 CompiledGraph (Execution Engine)

```ruby
module Phronomy
  module Graph
    class CompiledGraph
      include Phronomy::Runnable
      
      def initialize(state_class:, nodes:, edges:, conditional_edges:,
                     entry_point:, checkpointer:, interrupt_before:, interrupt_after:)
        @state_class = state_class
        @nodes = nodes
        @edges = edges
        @conditional_edges = conditional_edges
        @entry_point = entry_point
        @checkpointer = checkpointer
        @interrupt_before = interrupt_before
        @interrupt_after = interrupt_after
      end
      
      # Execute the graph
      # @param input [Hash] initial state
      # @param config [Hash] { thread_id:, recursion_limit: }
      def invoke(input, config: {})
        thread_id = config[:thread_id]
        recursion_limit = config.fetch(:recursion_limit, 25)
        
        # Resume from checkpoint or start fresh
        state = if @checkpointer && thread_id
          @checkpointer.load(thread_id) || @state_class.new(**input)
        else
          @state_class.new(**input)
        end
        
        result = execute_graph(state, thread_id:, recursion_limit:)
        result
      rescue Phronomy::Interrupt => e
        # Human-in-the-Loop: save suspended state and re-raise
        @checkpointer&.save(thread_id, e.state, interrupted_at: e.node)
        raise
      end
      
      # Resume a suspended graph
      # @param thread_id [String]
      # @param input [Hash] user input (nil to continue from saved state)
      def resume(thread_id:, input: nil)
        raise "Checkpointer not configured" unless @checkpointer
        
        checkpoint = @checkpointer.load(thread_id)
        raise "State not found for thread #{thread_id}" unless checkpoint
        
        state = input ? checkpoint.state.merge(input) : checkpoint.state
        execute_graph(state, from_node: checkpoint.interrupted_at, thread_id:)
      end
      
      # Streaming execution (yields an event after each node completes)
      def stream(input, config: {}, &block)
        thread_id = config[:thread_id]
        state = @state_class.new(**input)
        
        execute_graph_with_events(state, thread_id:) do |event|
          yield event if block_given?
        end
      end
      
      private
      
      def execute_graph(state, from_node: nil, thread_id: nil, recursion_limit: 25)
        current_node = from_node || @entry_point
        step = 0
        
        while current_node && current_node != StateGraph::END
          raise Phronomy::RecursionLimitError if step >= recursion_limit
          
          # interrupt_before check
          if @interrupt_before.include?(current_node)
            raise Phronomy::Interrupt.new(node: current_node, state:)
          end
          
          # Execute node
          node_fn = @nodes[current_node]
          raise "Node #{current_node} is not defined" unless node_fn
          
          updates = node_fn.call(state)
          state = state.merge(updates) if updates.is_a?(Hash)
          
          # Save checkpoint
          @checkpointer&.save(thread_id, state, completed_node: current_node)
          
          # interrupt_after check
          if @interrupt_after.include?(current_node)
            raise Phronomy::Interrupt.new(node: current_node, state:)
          end
          
          # Determine next node
          current_node = next_node(current_node, state)
          step += 1
        end
        
        state
      end
      
      def next_node(current, state)
        # Conditional edges take priority
        if (cond = @conditional_edges[current])
          result = cond[:condition].call(state)
          return cond[:mapping] ? cond[:mapping][result] : result
        end
        
        # Normal edges
        edges = @edges[current]
        return nil unless edges&.any?
        edges.first  # parallel execution is future work
      end
    end
  end
end
```

### 2.4 Usage Example

```ruby
# State definition
class ResearchState
  include Phronomy::Graph::State
  
  field :query,     type: :replace
  field :messages,  type: :append, default: -> { [] }
  field :research,  type: :replace
  field :answer,    type: :replace
end

# Graph definition
graph = Phronomy::Graph::StateGraph.new(ResearchState)

graph.add_node(:search) do |state|
  results = WebSearchTool.new.execute(query: state.query)
  { research: results }
end

graph.add_node(:answer) do |state|
  llm_response = RubyLLM.chat.ask(
    "Answer #{state.query} based on the following information:\n#{state.research}"
  )
  { answer: llm_response.content }
end

graph.add_node(:evaluate) do |state|
  needs_more = state.answer.include?("I don't know")
  { needs_more: needs_more }
end

graph.add_edge(:search, :answer)
graph.add_edge(:answer, :evaluate)

graph.add_conditional_edges(
  :evaluate,
  ->(state) { state.needs_more ? :search : Phronomy::Graph::StateGraph::END }
)

graph.set_entry_point(:search)

# Compile and run
checkpointer = Phronomy::Checkpointer::InMemory.new
compiled = graph.compile(
  checkpointer:,
  interrupt_before: [:search]  # require human confirmation before search
)

begin
  result = compiled.invoke(
    { query: "What are the new features in Ruby 3.3?" },
    config: { thread_id: "user_123" }
  )
rescue Phronomy::Interrupt => e
  puts "Confirm: about to execute #{e.node}. Continue? (y/n)"
  if gets.chomp == 'y'
    result = compiled.resume(thread_id: "user_123")
  end
end
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

Implemented as a Graph node, driven by the Graph execution engine.

```ruby
module Phronomy
  module Agent
    # ReAct pattern: Reasoning + Acting loop
    # Used as a node inside a Graph, or standalone
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

## 5. Checkpointer Component

### 5.1 Checkpointer Interface

```ruby
module Phronomy
  module Checkpointer
    Checkpoint = Struct.new(:thread_id, :state, :completed_node, :interrupted_at,
                            :created_at, keyword_init: true)
    
    class Base
      def save(thread_id, state, completed_node: nil, interrupted_at: nil)
        raise NotImplementedError
      end
      
      def load(thread_id)
        raise NotImplementedError
      end
      
      def list(thread_id)
        raise NotImplementedError
      end
      
      def delete(thread_id)
        raise NotImplementedError
      end
    end
    
    # In-memory implementation (for development and testing)
    class InMemory < Base
      def initialize
        @store = {}
        @history = Hash.new { |h, k| h[k] = [] }
      end
      
      def save(thread_id, state, completed_node: nil, interrupted_at: nil)
        checkpoint = Checkpoint.new(
          thread_id:,
          state:,
          completed_node:,
          interrupted_at:,
          created_at: Time.now
        )
        @store[thread_id] = checkpoint
        @history[thread_id] << checkpoint
        checkpoint
      end
      
      def load(thread_id)
        @store[thread_id]
      end
      
      def list(thread_id)
        @history[thread_id]
      end
      
      def delete(thread_id)
        @store.delete(thread_id)
        @history.delete(thread_id)
      end
    end
  end
end
```

### 5.2 ActiveRecord Persistence Implementation (Rails Integration)

```ruby
# migration
# create_table :phronomy_checkpoints do |t|
#   t.string :thread_id, null: false, index: true
#   t.string :completed_node
#   t.string :interrupted_at
#   t.text :state_json, null: false
#   t.timestamps
# end

module Phronomy
  module Checkpointer
    class ActiveRecord < Base
      def save(thread_id, state, completed_node: nil, interrupted_at: nil)
        record = CheckpointRecord.find_or_initialize_by(thread_id:)
        record.update!(
          state_json: state.to_h.to_json,
          completed_node:,
          interrupted_at:
        )
        
        # Also save history
        CheckpointHistoryRecord.create!(
          thread_id:,
          state_json: state.to_h.to_json,
          completed_node:,
          interrupted_at:
        )
        
        to_checkpoint(record, state)
      end
      
      def load(thread_id)
        record = CheckpointRecord.find_by(thread_id:)
        return nil unless record
        
        state_hash = JSON.parse(record.state_json, symbolize_names: true)
        Checkpoint.new(
          thread_id:,
          state: state_hash,  # caller restores to a State class
          completed_node: record.completed_node&.to_sym,
          interrupted_at: record.interrupted_at&.to_sym,
          created_at: record.updated_at
        )
      end
    end
  end
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

For fixed-order multi-agent pipelines, use Graph nodes directly:

```ruby
graph.add_node(:research) { |s| s.merge(research: ResearcherAgent.new.invoke(s.topic)[:output]) }
graph.add_node(:write)    { |s| s.merge(article: WriterAgent.new.invoke(s.research)[:output]) }
graph.add_edge(:research, :write)
graph.add_edge(:write, Phronomy::Graph::StateGraph::FINISH)
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
