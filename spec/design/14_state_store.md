# Phronomy — State Store

## 1. Overview

`StateStore` provides pluggable persistence for `Workflow` thread
state. This decouples the workflow runtime from any specific storage technology.

```ruby
Phronomy.configure do |c|
  c.state_store = Phronomy::StateStore::Redis.new(client: Redis.new)
end
```

The store is accessed by `WorkflowRunner#invoke` via `config[:thread_id]`:

```ruby
app.invoke({}, config: { thread_id: "user-42" })
```

When no store is configured, `InMemory` is used (data does not survive process
restart).

---

## 2. Class Hierarchy

```
Phronomy::StateStore::Base        (abstract)
├── Phronomy::StateStore::InMemory
├── Phronomy::StateStore::ActiveRecord
└── Phronomy::StateStore::Redis
```

---

## 3. StateStore::Base

`lib/phronomy/state_store/base.rb`

Abstract class. Subclasses must implement:

| Method | Signature | Contract |
|--------|-----------|---------|
| `save` | `(thread_id, state_hash)` | Persist state (any serialisable Hash) |
| `load` | `(thread_id) → Hash \| nil` | Return stored state or nil if absent |
| `clear` | `(thread_id)` | Delete stored state for that thread |

---

## 4. StateStore::InMemory

`lib/phronomy/state_store/in_memory.rb`

Hash-backed in-process store. Thread-safe via `Mutex`.

```ruby
store = Phronomy::StateStore::InMemory.new
store.save("t1", { messages: ["hello"] })
store.load("t1")   # => { messages: ["hello"] }
store.clear("t1")
store.load("t1")   # => nil
```

Used as the default when no store is configured.

---

## 5. StateStore::ActiveRecord

`lib/phronomy/state_store/active_record.rb`

Persists state as JSON in a database table using any ActiveRecord-compatible
model class.

### Constructor

```ruby
store = Phronomy::StateStore::ActiveRecord.new(
  model_class: PhronmyState,   # AR model with :thread_id and :state_json
  encryptor:   nil             # optional Encryptor::Base instance
)
```

### Expected schema

```sql
CREATE TABLE phronomy_states (
  id         BIGINT PRIMARY KEY AUTO_INCREMENT,
  thread_id  VARCHAR(255) NOT NULL UNIQUE,
  state_json TEXT         NOT NULL,
  created_at DATETIME,
  updated_at DATETIME
);
```

### Save / Load

- **Save**: `find_or_initialize_by(thread_id:)` then assign `state_json` and
  save.  If `encryptor:` is set, the JSON string is encrypted before storage
  and decrypted on load.
- **Load**: returns `JSON.parse(record.state_json, symbolize_names: true)` or
  `nil` if no record.
- **Clear**: `record&.destroy`.

---

## 6. StateStore::Redis

`lib/phronomy/state_store/redis.rb`

Persists state as a JSON string in Redis. Requires the `redis` gem.

```ruby
store = Phronomy::StateStore::Redis.new(
  client: Redis.new(url: ENV["REDIS_URL"]),
  ttl:    3600   # seconds; nil = no expiry
)
```

### Key convention

```
phronomy:state:<thread_id>
```

`KEY_PREFIX = "phronomy:state:"` (constant on the class).

### Save / Load / Clear

- **Save**: `SET phronomy:state:<thread_id> <json>` with optional `EX ttl`.
- **Load**: `GET key` → `JSON.parse(..., symbolize_names: true)` or nil.
- **Clear**: `DEL key`.

---

## 7. Encryptors

Optional encryption for `ActiveRecord` store.

### Encryptor::Base

`lib/phronomy/encryptor/base.rb`

```ruby
def encrypt(plaintext) → String   # must be overridden
def decrypt(ciphertext) → String  # must be overridden
```

### Encryptor::ActiveSupport

`lib/phronomy/encryptor/active_support.rb`

Uses `ActiveSupport::MessageEncryptor` with AES-256-GCM. Requires
`activesupport` gem.

```ruby
key   = ActiveSupport::KeyGenerator.new(ENV["SECRET_KEY_BASE"])
          .generate_key("phronomy_state", 32)
enc   = Phronomy::Encryptor::ActiveSupport.new(key: key)
store = Phronomy::StateStore::ActiveRecord.new(
  model_class: PhronmyState,
  encryptor:   enc
)
```

The encryptor wraps `ActiveSupport::MessageEncryptor.new(key)`. `encrypt` calls
`#encrypt_and_sign`; `decrypt` calls `#decrypt_and_verify`.

---

## 8. Integration with WorkflowRunner

`WorkflowRunner#invoke` loads and saves state automatically:

```ruby
def invoke(input, config: {})
  thread_id = config[:thread_id]
  stored    = thread_id ? @store.load(thread_id) : nil
  state     = build_initial_state(stored || {}, input)

  run_workflow(state, config).tap do |final|
    @store.save(thread_id, final) if thread_id
  end
end
```

This means resuming a suspended conversation is automatic — the caller only
needs to pass the same `thread_id`.

---

## 9. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Pluggable via single interface | Tests use InMemory; production uses AR or Redis — same code |
| `find_or_initialize_by` in AR store | One query for upsert logic without requiring `INSERT OR REPLACE` SQL |
| Redis TTL optional | Short-lived threads (chatbots) benefit from auto-expiry; long-lived agents set `nil` |
| Encryption at store level, not graph level | Keeps graph runtime pure; encryption is an infrastructure concern |
| `symbolize_names: true` on parse | State fields are accessed as symbols throughout the graph runtime |
