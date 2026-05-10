# Phronomy — Graph Parallel Node

## 1. Overview

`Graph::ParallelNode` executes multiple independent graph branches
concurrently within a `StateGraph`. Each branch receives the current state, runs
in its own Ruby `Thread`, and the results are merged back into a single state
using a configurable merge policy.

```ruby
graph.add_parallel_node(:my_step, branches: [:branch_a, :branch_b])
```

---

## 2. Class

`lib/phronomy/graph/parallel_node.rb`

---

## 3. Constructor

```ruby
Phronomy::Graph::ParallelNode.new(
  branches:   [:node_a, :node_b, :node_c],   # node names to run in parallel
  merge:      :replace,                       # :replace | :append | :merge (default: :replace)
  timeout:    nil,                            # Numeric (seconds) or nil (default: nil = unlimited)
  on_error:   :raise                          # :raise | :best_effort (default: :raise)
)
```

---

## 4. Merge Policies

| Policy | Behaviour |
|--------|-----------|
| `:replace` | Last branch to finish wins for each key (non-deterministic ordering) |
| `:append` | Values are concatenated (Arrays only; non-Array values are wrapped) |
| `:merge` | Deep merge — nested Hashes are recursively merged |

### Examples

Given two branch results `{ score: 0.8, tags: ["a"] }` and `{ score: 0.9, tags: ["b"] }`:

- `:replace` → `{ score: 0.9, tags: ["b"] }` (last write wins per key)
- `:append`  → `{ score: [0.8, 0.9], tags: ["a", "b"] }`
- `:merge`   → deep merge (scalars: last wins; Hashes: recursively merged)

---

## 5. Timeout

When `timeout:` is set:

- All threads are joined with `thread.join(timeout)`.
- If any thread fails to complete within the timeout, a
  `Phronomy::TimeoutError` is raised (regardless of `on_error:`).

When `timeout:` is `nil`, threads are joined without a time limit.

---

## 6. Error Handling

### `:raise` (default)

Any exception raised in any branch is re-raised in the main thread immediately
after all threads have been joined. If multiple branches fail, the first
exception encountered is raised.

### `:best_effort`

Branch exceptions are caught and stored. Successful branches contribute their
results to the merged state. The errors are stored in the state under the key
`:parallel_errors`:

```ruby
state[:parallel_errors]
# => [{ branch: :node_a, error: <RuntimeError: ...> }, ...]
```

---

## 7. StateGraph DSL

`StateGraph#add_parallel_node` registers the parallel node and a corresponding
set of individual branch nodes:

```ruby
graph = Phronomy::Graph::StateGraph.new(MyState)

graph.add_node(:fetch_data)    { |s| s.merge(data: load_data) }
graph.add_node(:compute_stats) { |s| s.merge(stats: compute(s[:data])) }

# Define branches as sub-nodes, then group them in a parallel node
graph.add_parallel_node(
  :enrich,
  branches:  [:fetch_data, :compute_stats],
  merge:     :append,
  timeout:   10,
  on_error:  :best_effort
)

graph.set_entry_point(:enrich)
graph.add_edge(:enrich, Phronomy::Graph::StateGraph::FINISH)
```

---

## 8. Thread Safety

Each branch receives a **deep copy** of the state (via `Marshal.dump` /
`Marshal.load`) to prevent branches from reading each other's mutations.
After all branches complete, results are merged in the main thread.

---

## 9. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Ruby `Thread` (not Ractor) | Ractor restricts shareable objects; Thread is simpler and compatible with all current phronomy state types |
| Deep copy via Marshal | Prevents subtle race conditions when branches read shared mutable objects |
| `:replace` as default merge | Safest default; user must opt into `:append` / `:merge` explicitly |
| `:parallel_errors` in state | Keeps error information in-band; caller can inspect and decide what to do |
| `timeout:` applies to entire parallel step | Simpler mental model than per-branch timeouts |
| `add_parallel_node` DSL | Keeps graph definition declarative; parallel semantics are explicit in the topology |
