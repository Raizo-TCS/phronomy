# R8 unit20: Passive Engine observation

## Problem

Metrics.snapshot previously called Runtime.instance, Runtime#offload and
Runtime#event_loop. A cold snapshot constructed the default Runtime, started
default-pool workers and started the EventLoop. Looking at an existing Runtime
could initialize its other resources. The same calls rejected observation after
shutdown, precisely when diagnostics were useful. Diagnostics.snapshot and dump
inherited these effects through Metrics.snapshot.

## Responsibility

Runtime retains ownership of its singleton and resource references. PoolRegistry
retains ownership of its default pool. Both provide internal lookup operations
using their existing mutexes, without construction or admission checks. Runtime's
existing EventLoop lookup already provides the same behavior. These lookups can
observe retained resources after shutdown without reopening them.

Metrics samples the returned resources and formats the existing ten numeric
fields. It does not inspect instance variables, decide resource initialization,
read configuration as a substitute for measurements, or cache Runtime references.
The test-only singleton lookup delegates to the internal lookup; production code
does not call a test helper. RBS describes the optional resource references.

## Behavior and scope

Missing resources contribute zero. An uninitialized default pool therefore has
size zero even if configuration would allocate ten workers on first use. For an
existing pool, size continues to describe configured capacity, including after
shutdown; it is not a count of living workers. Named pools remain outside these
default-pool metrics. A subsequent snapshot follows the current default Runtime,
so a reset neither recreates it nor keeps stale metrics in a cache.

Counters remain independent observations. Concurrent activity or Runtime reset
can occur during a snapshot; no globally atomic observation or lifecycle barrier
is promised. Resource references are obtained under their owners' existing locks
and metrics are read after those lookup locks are released. No new lock ordering,
polling thread, subscription, observer registry or notification mechanism is added.

Unit19 pool creation and shutdown rules, cancellation, domain finalization,
shutdown deadlines and cached shutdown results are unchanged. Contract/domain
code and dependencies are unchanged. All product-code changes stay in Engine.

## Verification

A fresh-process test exercises all three observation entry points and checks that
no Runtime or thread is created. Tests cover partial initialization, named pools,
real active/queued/abandoned worker metrics, EventLoop backlog and lag, draining,
stopping, completed and incomplete shutdown, and default Runtime replacement.
Queue barriers control concurrent boundaries without relying on chance schedules.
