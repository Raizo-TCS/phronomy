# A bounded Workflow completion recipe

The proposed generic `Phronomy::Integrations::WorkflowCompletion.forward` API is
not introduced. `Workflow#signal` addresses a logical Workflow ID, not a specific
execution or entry into a waiting state. That proposed signature cannot by itself
prevent an old completion from reaching a later waiting stage. No new execution
generation, child registry or automatic recovery is added to solve this here.

Use the application-local function below only for **one live waiting stage, with
no restart, reentry or replacement while its operation is pending**. It separates
result mapping (application logic) from the repetitive notification plumbing.
For repeated/resumed stages, the app must put an operation ID in every success
AND error payload and check it with a receiver-side transition `guard:` before
applying the payload. Signal admission alone is not that check. The example
below intentionally does not claim that wider guarantee.

```ruby runnable
def forward_completion(task, workflow:, workflow_instance_id:, event:, on_delivery_error:)
  task.on_complete do |payload, operation_error|
    delivery_error = nil
    begin
      accepted = workflow.signal(
        workflow_instance_id: workflow_instance_id, event: event,
        payload: operation_error ? {error: operation_error} : payload
      )
      delivery_error = Phronomy::Error.new("Workflow did not accept #{event}") unless accepted
    rescue => error
      delivery_error = error
    end
    on_delivery_error.call(delivery_error) if delivery_error
  end
  nil
end

class RecipeAnswerAgent < Phronomy::Agent::Base
  agent_definition id: "bounded-completion-recipe", version: 1
  model "gpt-4o-mini"
  instructions "Answer briefly."
end
class CompletionState
  include Phronomy::WorkflowContext
  field :question, type: :replace
  field :answer, type: :replace
  field :error_message, type: :replace
end

agent = RecipeAnswerAgent.new
errors = Queue.new
workflow = nil
workflow = Phronomy::Workflow.define(CompletionState) do
  initial :asking
  state :asking
  state :done
  entry :asking, ->(state) {
    task = agent.invoke_async(state.question).map { |result| {answer: result.fetch(:output)} }
    forward_completion(task, workflow: workflow,
      workflow_instance_id: state.workflow_instance_id, event: :answer_ready,
      on_delivery_error: ->(error) { errors << error })
    state
  }
  transition from: :asking, on: :answer_ready, to: :done,
    action: ->(state, event) {
      error = event.payload[:error]
      error ? state.merge(error_message: error.message) : state.merge(answer: event.payload.fetch(:answer))
    }
  transition from: :done, to: :__finish__
end
final = workflow.invoke({question: "Explain completion handles"},
  config: {workflow_instance_id: "bounded-recipe"})
puts final.error_message || final.answer
raise errors.pop unless errors.empty?
```

`forward_completion` returns nil after registering one callback. Already-completed
results are notified immediately. Two registrations are two subscriptions; the
application avoids duplicates. No task state is changed, no retry is attempted,
and no callback waits for execution, storage or network delivery.

Operation failures and cancellation notify the Workflow with `{error: error}`.
A false signal result and a raised signal exception each notify the required
`on_delivery_error` callback once. A failure of that callback follows TaskResult's
existing logger policy; it is not retried and does not rewrite the task result.
The application observes delivery errors and chooses cancellation/recovery.

Signal acceptance does not guarantee transition completion or a durable save.
Incomplete tasks retain their subscriptions until settlement under the existing
TaskResult lifecycle. The caller still owns operation cancellation and lifetime;
this recipe installs no Runtime shutdown hook or global subscription registry.

See [the full application recipe](application-recipes.md#workflow-completion-and-failures)
for the same failure behavior without extracting this application-local function.
