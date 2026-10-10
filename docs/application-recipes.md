# Application recipes

Start with [Getting started](getting-started.md). Every `ruby runnable` block
below is a complete example after `require "phronomy"` and provider configuration.
CI substitutes only the LLM adapter; Agent, Tool and Workflow operations are real.

## Choose the completion channel

| Need | Public API | Caller responsibility |
|---|---|---|
| One final answer | `agent.invoke(input)` | Call from an external thread |
| Nonblocking final answer | `agent.invoke_async(input)` | Observe the returned TaskResult |
| Intermediate events | Construction-time `on_event:` | Keep the callback short |
| Streamed tokens | `stream` / `stream_async` with a listener | Move network delivery out of the callback |
| Durable approval | `approve_async` with the request IDs | Apply the application's authorization decision |
| Live Workflow notification | `workflow.signal(...)` | Check admission; correlate the waiting operation |

`TaskResult#wait_result` waits at an external application boundary. Completion
callbacks and Agent listeners must not block EventLoop. A wait timeout does not
cancel the underlying operation. The caller owns cancellation and cleanup.

## Create, load and get

```ruby runnable
class ConversationAgent < Phronomy::Agent::Base
  agent_definition id: "recipe-conversation", version: 1
  model "gpt-4o-mini"
  instructions "Answer briefly."
end

store = Phronomy::PersistenceComposition.in_memory.agent
agent = ConversationAgent.create(agent_id: "recipe-session", persistence: store)
puts agent.invoke("Hello").fetch(:output)

# A live lookup is not a database read. Loading a live identity returns its owner.
raise "Unexpected owner" unless ConversationAgent.get("recipe-session").equal?(agent)
raise "Unexpected load" unless ConversationAgent.load("recipe-session", persistence: store).equal?(agent)

def load_existing_agent(agent_class:, agent_id:, persistence:)
  agent_class.load(agent_id, persistence: persistence)
rescue Phronomy::Persistence::NotFoundError
  nil
end

missing = load_existing_agent(
  agent_class: ConversationAgent, agent_id: "missing-session", persistence: store
)
raise "Expected a missing Agent" unless missing.nil?
```

This application treats only absence as `nil`. Storage unavailability, state
conflicts and recovery requirements remain errors. `create` is not upsert; do
not catch every persistence failure and create a replacement conversation.
The in-memory store is for this example; a durable backend must outlive Runtime
to support process restart. See [persistence failures](migrations/persistence-failure-contracts.md).

## Streaming and final results

```ruby runnable
class StreamingAgent < Phronomy::Agent::Base
  agent_definition id: "recipe-streaming", version: 1
  model "gpt-4o-mini"
  instructions "Explain briefly."
end

events = Queue.new
agent = StreamingAgent.new(on_event: ->(event) {
  events << event if event.type == :token
})

task = agent.stream_async("Explain asynchronous results")
result = task.wait_result
puts result.fetch(:output)
puts "Received #{events.size} token events"
```

The unbounded Queue is an in-process teaching example. A Web application needs
bounded admission and ordered delivery outside the listener, such as Example 18.
Register the listener at `new`/`create`/first `load`; per-invocation listener
arguments or blocks are rejected. Do not replace a listener by loading an
already-live Agent. See [approval](getting-started.md#human-in-the-loop-approval)
for the separate durable approval identifiers and application decision.

## Workflow completion and failures

The [minimal connection](getting-started.md#workflow-basics) preserves the
success-only purpose of the old event-block example. The following recipe adds
operation failure/cancellation and delivery failure handling. Those are additional
application behaviors, not extra arguments required for a successful call.

This recipe targets **one live waiting stage**. Do not restart, reenter or replace
that stage while a result is pending. A logical `workflow_instance_id` alone does
not identify a particular execution or waiting operation. For those wider cases,
application operation IDs and receiver-side guards are necessary.

```ruby runnable
def request_answer(agent:, workflow:, workflow_instance_id:, question:,
  on_delivery_error:)
  task = agent.invoke_async(question).map do |result|
    {answer: result.fetch(:output)}
  end

  task.on_complete do |payload, operation_error|
    delivery_error = nil
    begin
      accepted = workflow.signal(
        workflow_instance_id: workflow_instance_id,
        event: :answer_ready,
        payload: operation_error ? {error: operation_error} : payload
      )
      unless accepted
        delivery_error = Phronomy::Error.new("Workflow did not accept answer_ready")
      end
    rescue => error
      delivery_error = error
    end
    on_delivery_error.call(delivery_error) if delivery_error
  end

  nil
end

class AnswerAgent < Phronomy::Agent::Base
  agent_definition id: "recipe-answer", version: 1
  model "gpt-4o-mini"
  instructions "Answer briefly."
end

class AnswerState
  include Phronomy::WorkflowContext
  field :question, type: :replace
  field :answer, type: :replace
  field :error_message, type: :replace
end

agent = AnswerAgent.new
delivery_errors = Queue.new
workflow = nil
workflow = Phronomy::Workflow.define(AnswerState) do
  initial :asking
  state :asking
  state :done
  entry :asking, ->(state) {
    request_answer(
      agent: agent, workflow: workflow,
      workflow_instance_id: state.workflow_instance_id, question: state.question,
      on_delivery_error: ->(error) { delivery_errors << error }
    )
    state
  }
  transition from: :asking, on: :answer_ready, to: :done,
    action: ->(state, event) {
      error = event.payload[:error]
      error ? state.merge(error_message: error.message) : state.merge(answer: event.payload.fetch(:answer))
    }
  transition from: :done, to: :__finish__
end

final = workflow.invoke(
  {question: "What is a completion handle?"},
  config: {workflow_instance_id: "recipe-answer"}
)
puts final.error_message || final.answer
raise delivery_errors.pop unless delivery_errors.empty?
```

The receiver handles both answer and error; changing only the sender would be
incomplete. Store a serializable diagnostic, not the exception object, in the
Workflow context. Result mapping failures (such as a missing `:output`) also
become operation failures. Synchronous submission errors still propagate to
the caller of `request_answer`.

`signal == true` means admission, not transition completion or durable success.
`false` and signal exceptions reach `on_delivery_error` once without automatic
retry. This callback must be short and nonblocking. Its own exceptions follow
TaskResult's existing callback logging policy; they do not change the settled
operation result. Logging depends on the configured logger.

Delivery rejection does not itself settle a waiting Workflow. The application
must observe its diagnostic channel and decide whether to cancel or recover.
The synchronous invocation above illustrates successful delivery. Production
callers needing a wait limit should use `invoke_async` and manage both the
Workflow TaskResult and the diagnostic channel at their external boundary.

No generic Workflow forwarding helper is required by these recipes. A helper
must first establish how an old result is prevented from reaching a new waiting
stage; internal execution generations or automatic recovery are not implied.
