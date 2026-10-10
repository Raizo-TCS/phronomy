# Ordered event delivery

Load the application integration explicitly:

```ruby
require "phronomy"
require "phronomy/integrations/ordered_event_delivery"

Phronomy::Integrations::OrderedEventDelivery.open(
  capacity: 256, batch_size: 32, flush_timeout: 30,
  deliver: ->(payload) { send_to_application_transport(payload) }
) do |delivery|
  agent = MyAgent.new(on_event: ->(event) {
    payload = application_payload(event)
    delivery.publish(payload) if payload
  })
  agent.stream("Hello")
end
```

The block runs on the external caller, and its result is returned after drain.
`open` rejects EventLoop callers before executing their block. Publication only
snapshots and queues plain data; it does not wait for capacity or send network
traffic. The existing Blocking API supplies a worker only while draining. The
integration creates no scheduler and never shuts down the shared Runtime/pool.

The app owns authentication, destination, authorization, Rails executor wrapping,
event-to-payload conversion, and any token coalescing. `prepare_batch:` optionally
receives an immutable Array of snapshots on the drain worker and returns an Array
of payloads to send in order. Its default is no transformation. Example 18 passes
its own TokenEventBatch, preserving adjacent-token coalescing with equal metadata.

Capacity limits the waiting queue, excluding an already extracted batch. Multiple
publishers are ordered by queue admission, not by thread start time. Hashes,
Arrays, Strings and scalar plain values are copied into immutable snapshots;
cycles, non-finite numbers and arbitrary objects fail publication.

On overflow/invalid publication, acceptance closes and the failure remains visible
to final drain even if an Agent listener merely logs its exception. Previously
accepted work drains if transport is healthy. A failed batch conversion, delivery
or worker admission also closes acceptance; remaining work may not be delivered.
There is no silent drop-as-success, automatic retry or durable delivery guarantee.

`close_and_wait` can be called by multiple external threads. It waits for physical
drain completion, not just TaskResult settlement. A timeout ends only the wait;
a network operation can still complete afterwards. Configure transport timeouts
in the transport itself. Network failure does not prove that nothing was sent.

If application execution fails, its original exception, message and backtrace
remain primary after cleanup. A simultaneous delivery failure is reported through
the configured Phronomy logger. Without a logger there is no durable diagnostic
guarantee; logger failure falls back to stderr without replacing the primary error.
If only delivery fails, that failure is raised. The small final-answer-only Job
needs no queue and is unchanged.
