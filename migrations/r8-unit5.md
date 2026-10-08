# r8 unit 5 API migration

Apply core and examples together. No saved Agent, MultiAgent or Workflow record
format changes in this unit. Old constants and forwarding aliases are removed.

| Previous API | Current API |
| --- | --- |
| `Phronomy::VectorStore::Embeddings::*` | `Phronomy::Embeddings::*` |
| `Phronomy::VectorStore::Loader::*` | `Phronomy::Documents::Loader::*` |
| `Phronomy::VectorStore::Splitter::*` | `Phronomy::Documents::Splitter::*` |

VectorStore callers continue using `add`, `search`, `remove`, `clear` and `size`.
Custom backends now override protected `perform_add`, `perform_search`,
`perform_remove`, `perform_clear`, `perform_size`, and optionally
`embedding_dimension`. The common Base performs input/result validation and
returns `self` for add/remove/clear; the return value from these three hooks is
ignored. See `sig/phronomy/vector_store/base.rbs` for exact arguments. RBS models
the non-public hooks as private because it cannot express Ruby protected visibility.

Custom embedding providers implement the protected hook, not the public template:

```ruby
class KeywordEmbeddings < Phronomy::Embeddings::Base
  protected

  def perform_embed(text, cancellation_token = nil)
    # Common input/result validation and the initial cancellation checkpoint
    # are inherited. Long-running implementations may check the signal again.
    [text.scan(/refund/i).length.to_f, text.scan(/shipping/i).length.to_f]
  end
end

provider = KeywordEmbeddings.new
vector = provider.embed("refund")
task = Phronomy::Embeddings::AsyncClient.new(adapter: provider).embed_async("shipping")
result = task.wait_result
```

Embedding input must be a String, including an optional empty string; output must
be a non-empty Array of finite real numbers. Provider output is copied to a Float
array. An empty or malformed vector raises `Embeddings::InvalidResultError`.
RubyLLM provider failures now raise `Embeddings::TransportError`; inspect `cause`
for provider-specific details. Application exceptions are unchanged.

Vector ids must be Strings and metadata must be a Hash. Numeric strings, NaN,
infinity and complex components are rejected before backend I/O. Zero-dimensional
vectors still work in InMemory. `k` accepts positive Integers or decimal strings,
including `"08"`; Float truncation, hexadecimal/octal interpretation, whitespace
and arbitrary `to_int` coercions are not part of the contract. Results must satisfy
the public shape, score ordering and limit. Invalid backend results raise
`VectorStore::InvalidResultError`; they are never retried automatically.

Update custom backend tests to exercise inherited public operations. Do not
silence malformed results, return a fake zero count on transport failure, or add
an old-name alias to bypass the migration. Real Pgvector and RedisSearch deployments
must run their actual-service conformance tests before rollout.

The revised unit 5 candidate also tightens concrete backend response decoding.
RedisSearch expects RESP2; a missing whole search reply, malformed field pairs,
invalid counts or non-numeric distances now fail with `InvalidResultError` rather
than becoming an empty result, zero count or similarity 1. Document contents that
Redis explicitly reports as null during expiration/update are still omitted.
The total match count may exceed the returned page; these valid cases are tested.
RESP3 is not introduced by this update.

For Pgvector, a NULL metadata column remains `{}`, while an empty string, invalid
JSON, or JSON that is not an object now fails. An already-decoded Hash and a JSON
object remain accepted. Redis missing/null metadata likewise remains `{}`.
Pgvector rejects malformed scores and ids; integer database ids are still mapped
to String. JSON parser errors are retained as `cause`. Connection errors remain
unchanged and are not retried.

Check pre-existing metadata for invalid JSON or non-object values before rollout;
do not silently replace corrupt values with `{}` to make verification pass.
These parsing rules are implemented by the respective backend, not by Base.
