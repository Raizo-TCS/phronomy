# frozen_string_literal: true

require "active_record"
require "logger"

# Connect to an in-memory SQLite database (no external server required).
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Suppress SQL noise in test output. Set to Logger.new($stdout) to debug.
ActiveRecord::Base.logger = Logger.new(IO::NULL)

# Create the phronomy tables used by Memory::Storage::ActiveRecord.
ActiveRecord::Schema.define(version: 1) do
  create_table :phronomy_messages, force: true do |t|
    t.string :thread_id, null: false
    t.string :role, null: false
    t.text :content
    t.text :tool_calls_json
    t.string :model_id
    t.timestamps
  end

  create_table :phronomy_states, force: true do |t|
    t.string :thread_id, null: false, index: {unique: true}
    t.text :state_json, null: false
    t.timestamps
  end
end

# Minimal ActiveRecord model mirroring the generator template.
class PhronomyMessageRecord < ActiveRecord::Base
  self.table_name = "phronomy_messages"
  include Phronomy::ActiveRecord::Message
end

# Minimal ActiveRecord model for StateStore::ActiveRecord tests.
class PhronomyStateRecord < ActiveRecord::Base
  self.table_name = "phronomy_states"
end
