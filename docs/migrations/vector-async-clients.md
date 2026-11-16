# VectorStore and Embeddings: asynchronous client migration

The P3 migration separated asynchronous submission from synchronous backend
operations. Current applications call explicit Beta clients, while backend
authors implement protected synchronous hooks behind the common templates.

For example, an application calls `async_store.search_async` to schedule the same
public search operation that `store.search` performs synchronously. The current
namespace and hook SPI also include the later [unit 5 migration](r8-unit5.md).

| Previous receiver | New receiver |
|---|---|
| `store.add_async(...)` | `async_store.add_async(...)` |
| `store.search_async(...)` | `async_store.search_async(...)` |
| `store.remove_async(...)` | `async_store.remove_async(...)` |
| `store.clear_async(...)` | `async_store.clear_async(...)` |
| `embeddings.embed_async(text, token, timeout: seconds)` | `async_embeddings.embed_async(text, token, timeout: seconds)` |

Construct the clients with `VectorStore::AsyncClient.new(backend: store)` and
`Embeddings::AsyncClient.new(adapter: embeddings)`. The embedding
cancellation token stays positional. Synchronous `add`, `search`, `remove`,
`clear`, `size` and `embed` stay on the existing backend objects.

`VectorStore::AsyncBackend` and inherited async methods are removed. There is
no include/prepend, backend `.async` factory, or automatic compatibility shim.
Update the receiver wherever an application previously called an async method.
The clients are public Beta API; their `async/` directories do not introduce
`Phronomy::Async` or feature-specific `Async` namespaces.

## Complete offline example

This example uses an intentionally simple local embedding adapter to demonstrate
the API. It needs no provider key, network request, or database server. The
implementation supplies protected `perform_embed`; the inherited public `embed`
validates input and result, and Phronomy supplies asynchronous execution. The
example uses the current unit 5 namespace and extension SPI, which supersede
the original P3 adapter names.

```ruby runnable
require "phronomy"
require "json"

class KeywordEmbeddings < Phronomy::Embeddings::Base
  protected

  def perform_embed(text, cancellation_token = nil)
    cancellation_token&.raise_if_cancelled!
    words = text.downcase
    [words.include?("ruby") ? 1.0 : 0.0,
      words.include?("python") ? 1.0 : 0.0]
  end
end

begin
  store = Phronomy::VectorStore::InMemory.new(dimension: 2)
  embeddings = KeywordEmbeddings.new
  async_store = Phronomy::VectorStore::AsyncClient.new(backend: store)
  async_embeddings = Phronomy::Embeddings::AsyncClient.new(adapter: embeddings)

  {"ruby" => "Ruby guide", "python" => "Python guide"}.each do |id, title|
    async_embeddings.embed_async(title).flat_map do |vector|
      async_store.add_async(id: id, embedding: vector, metadata: {title: title})
    end.wait_result
  end

  matches = async_embeddings.embed_async("Ruby").flat_map do |vector|
    async_store.search_async(query_embedding: vector, k: 1)
  end.wait_result
  puts JSON.generate(matches)
ensure
  Phronomy.reset_runtime!
end
```

The result contains the `ruby` document. The application waits only outside
worker callbacks; `flat_map` returns the next TaskResult without blocking a
worker on another operation. `Tools::VectorSearch` continues to call synchronous
`embed` and `search` inside its existing execution boundary, so this migration
does not add nested offload work to that Tool.

## Execution and cancellation

Both clients accept optional `pool:` injection. Usually omit it. Construction
starts no Runtime, and each operation resolves the current default pool. An
explicit pool remains caller-owned across Runtime resets; it must provide the
existing OffloadPool submit contract, including its timer service for timeouts.

Queue admission uses `on_full: :raise`. A full or stopped pool raises immediately;
an accepted operation returns the original TaskResult. Timeout includes queue
wait. Cancellation or timeout before worker pickup skips the operation; after
execution starts it settles the result without forcibly stopping I/O or undoing
backend effects. These are the existing OffloadPool semantics.

Synchronous RBS signatures accept the structural `_CancellationSignal`
interface, which requires only `raise_if_cancelled!`. Existing
`Concurrency::CancellationToken` objects still satisfy it. Async RBS signatures
live in `sig/phronomy/vector_store/async/async_client.rbs` and
`sig/phronomy/embeddings/async/async_client.rbs` and retain the full CancellationToken
and TaskResult contract needed by the execution pool. Do not substitute a
minimal synchronous signal for an async operation's full token.

## Source ownership

Concrete implementations remain separate from their common operation contracts.
For example, a vector store keeps its algorithm in `vector_store/backends/`,
while an embedding provider lives in the independent `embeddings/backends/`
directory introduced by the [unit 5 migration](r8-unit5.md).

| Current public class | Path under `lib/phronomy/` |
|---|---|
| `VectorStore::InMemory` | `vector_store/backends/in_memory.rb` |
| `VectorStore::Pgvector` | `vector_store/backends/pgvector.rb` |
| `VectorStore::RedisSearch` | `vector_store/backends/redis_search.rb` |
| `Embeddings::RubyLLMEmbeddings` | `embeddings/backends/ruby_llm_embeddings.rb` |

Use `require "phronomy"` and the public constants. Direct partial-load paths are
not the public loading contract; no require shim is kept in the contract
directories. Backend Contracts have no execution or implementation dependency.
P4 Storage/ContentStore work is implemented; see the
[Storage asynchronous execution guide](storage-async-client.md).
[ADR-062](../decisions/062-content-store-service.md) subsequently classified
ContentStore as a content service over Storage, rather than a physical backend.
The final P5 cross-repository/API/documentation review remains pending, as
recorded in [Backend responsibilities](../architecture/backend-groups.md).
