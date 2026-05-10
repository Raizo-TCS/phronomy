# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tempfile"
require_relative "../support/active_record_setup"

# State class for testing
class StoreTestState
  include Phronomy::Graph::State

  field :value, type: :replace, default: 0
end

def make_state(value:, thread_id: "t1", current_nodes: [], halted_before: false)
  s = StoreTestState.new(value: value)
  s.set_graph_metadata(thread_id: thread_id, current_nodes: current_nodes, halted_before: halted_before)
  s
end

RSpec.describe Phronomy::StateStore::Base do
  subject(:store) { described_class.new }

  it "raises NotImplementedError for save" do
    expect { store.save(make_state(value: 1)) }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for load" do
    expect { store.load("t1") }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for clear" do
    expect { store.clear("t1") }.to raise_error(NotImplementedError)
  end
end

RSpec.describe Phronomy::StateStore::InMemory do
  subject(:store) { described_class.new }

  describe "#save / #load" do
    it "saves and retrieves state by thread_id" do
      state = make_state(value: 42, thread_id: "t1")
      store.save(state)
      loaded = store.load("t1")
      expect(loaded.value).to eq(42)
    end

    it "preserves thread_id in loaded state" do
      state = make_state(value: 1, thread_id: "mythread")
      store.save(state)
      expect(store.load("mythread").thread_id).to eq("mythread")
    end

    it "preserves current_nodes in loaded state" do
      state = make_state(value: 1, thread_id: "t1", current_nodes: [:send], halted_before: true)
      store.save(state)
      loaded = store.load("t1")
      expect(loaded.current_nodes).to eq([:send])
      expect(loaded.halted_before).to be(true)
    end

    it "save returns self for chaining" do
      expect(store.save(make_state(value: 1, thread_id: "t1"))).to be(store)
    end

    it "returns nil for unknown thread_id" do
      expect(store.load("unknown")).to be_nil
    end

    it "manages multiple threads independently" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 2, thread_id: "t2"))
      expect(store.load("t1").value).to eq(1)
      expect(store.load("t2").value).to eq(2)
    end

    it "overwrites an existing state on re-save" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 99, thread_id: "t1"))
      expect(store.load("t1").value).to eq(99)
    end
  end

  describe "#clear" do
    it "removes the state for the given thread_id" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.clear("t1")
      expect(store.load("t1")).to be_nil
    end

    it "clear returns self for chaining" do
      store.save(make_state(value: 1, thread_id: "t1"))
      expect(store.clear("t1")).to be(store)
    end

    it "does not affect other threads" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 2, thread_id: "t2"))
      store.clear("t1")
      expect(store.load("t2").value).to eq(2)
    end
  end

  describe "#clear_all" do
    it "removes all stored states" do
      store.save(make_state(value: 1, thread_id: "t1"))
      store.save(make_state(value: 2, thread_id: "t2"))
      store.clear_all
      expect(store.load("t1")).to be_nil
      expect(store.load("t2")).to be_nil
    end
  end
end

RSpec.describe "Phronomy::Graph class registry" do
  after { Phronomy::Graph.reset_state_class_registry! }

  describe ".register_state_class" do
    it "adds the class to the registry keyed by name" do
      Phronomy::Graph.register_state_class(StoreTestState)
      expect(Phronomy::Graph.state_class_registry[StoreTestState.name]).to eq(StoreTestState)
    end

    it "accepts multiple classes at once" do
      Phronomy::Graph.register_state_class(StoreTestState, StoreTestState)
      expect(Phronomy::Graph.state_class_registry).to have_key(StoreTestState.name)
    end
  end

  describe ".reset_state_class_registry!" do
    it "clears the registry back to nil" do
      Phronomy::Graph.register_state_class(StoreTestState)
      Phronomy::Graph.reset_state_class_registry!
      expect(Phronomy::Graph.state_class_registry).to be_nil
    end
  end

  describe "StateStore::Base#safe_state_class with registry" do
    let(:store_instance) { Phronomy::StateStore::InMemory.new }

    it "allows a registered class" do
      Phronomy::Graph.register_state_class(StoreTestState)
      klass = store_instance.send(:safe_state_class, StoreTestState.name)
      expect(klass).to eq(StoreTestState)
    end

    it "raises ArgumentError for an unregistered class when registry is present" do
      Phronomy::Graph.register_state_class(StoreTestState)
      expect {
        store_instance.send(:safe_state_class, "UnregisteredClass")
      }.to raise_error(ArgumentError, /Unregistered state class/)
    end
  end
end

RSpec.describe "CompiledGraph and StateStore integration" do
  def build_compiled
    g = Phronomy::Graph::StateGraph.new(StoreTestState)
    g.add_node(:step1) { |s| {value: s.value + 10} }
    g.add_node(:step2) { |s| {value: s.value + 1} }
    g.add_edge(:step1, :step2)
    g.set_entry_point(:step1)
    g.compile
  end

  around do |example|
    Phronomy.configure { |c| c.default_state_store = Phronomy::StateStore::InMemory.new }
    example.run
    Phronomy.reset_configuration!
  end

  it "saves final state to store after normal completion" do
    compiled = build_compiled
    result = compiled.invoke({value: 0})
    store = Phronomy.configuration.default_state_store
    saved = store.load(result.thread_id)
    expect(saved).not_to be_nil
    expect(saved.value).to eq(11)
  end

  it "saves halted state to store on interrupt_before" do
    compiled = build_compiled
    compiled.interrupt_before(:step2) { |_s| :halt }
    halted = compiled.invoke({value: 0})

    store = Phronomy.configuration.default_state_store
    saved = store.load(halted.thread_id)
    expect(saved.current_nodes).to eq([:step2])
    expect(saved.halted_before).to be(true)
  end

  it "resumes and completes, then stores final state" do
    compiled = build_compiled
    compiled.interrupt_before(:step2) { |_s| :halt }
    halted = compiled.invoke({value: 0})

    final = compiled.resume(state: halted)
    expect(final.value).to eq(11)
    expect(final.current_nodes).to eq([])
  end
end

RSpec.describe "CompiledGraph and StateStore::ActiveRecord: true cross-process interrupt and resume" do
  # Returns the phronomy/ gem root directory (two levels up from spec/phronomy/).
  def gem_root
    File.expand_path("../..", __dir__)
  end

  # Ruby script run in a real subprocess (Process 2).
  # It reads the halted state from the file DB and resumes the graph.
  def subprocess_script(db_path, result_path)
    <<~RUBY
      # frozen_string_literal: true
      require "bundler/setup"
      require "phronomy"
      require "active_record"
      require "json"

      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: #{db_path.inspect})

      class PhronomyXprocModel < ActiveRecord::Base
        self.table_name = "phronomy_xproc_states"
      end

      # Must match the class name embedded by serialize_state in Process 1.
      class StoreTestState
        include Phronomy::Graph::State
        field :value, type: :replace, default: 0
      end

      store = Phronomy::StateStore::ActiveRecord.new(model_class: PhronomyXprocModel)
      loaded = store.load("xproc-test")
      raise "State not found in DB" if loaded.nil?

      graph = Phronomy::Graph::StateGraph.new(StoreTestState)
      graph.add_node(:step1) { |s| {value: s.value + 10} }
      graph.add_node(:step2) { |s| {value: s.value + 1} }
      graph.set_entry_point(:step1)
      graph.add_edge(:step1, :step2)
      graph.add_edge(:step2, Phronomy::Graph::StateGraph::FINISH)
      app = graph.compile

      final = app.resume(state: loaded)
      File.write(#{result_path.inspect}, JSON.generate({value: final.value, current_nodes: final.current_nodes}))
    RUBY
  end

  it "halts mid-graph, persists state to a file DB, and a real subprocess resumes it" do
    db_file = result_file = script_file = nil

    db_file = Tempfile.new(["phronomy_state_xproc", ".db"])
    db_path = db_file.path
    db_file.close

    result_file = Tempfile.new(["phronomy_resume_result", ".json"])
    result_path = result_file.path
    result_file.close

    script_file = Tempfile.new(["phronomy_xproc_script", ".rb"])
    script_path = script_file.path
    script_file.write(subprocess_script(db_path, result_path))
    script_file.flush
    script_file.close

    # --- Process 1: run graph until halt, write state to file-based SQLite ---
    # Use an isolated abstract AR base so the :memory: connection is unaffected.
    xproc_base = Class.new(ActiveRecord::Base) { self.abstract_class = true }
    Object.const_set(:PhronomyXprocBase, xproc_base)
    PhronomyXprocBase.establish_connection(adapter: "sqlite3", database: db_path)
    PhronomyXprocBase.connection.create_table(:phronomy_xproc_states, force: true) do |t|
      t.string :thread_id, null: false
      t.text :state_json, null: false
      t.timestamps
    end
    PhronomyXprocBase.connection.add_index(:phronomy_xproc_states, :thread_id, unique: true)

    xproc_model = Class.new(PhronomyXprocBase) { self.table_name = "phronomy_xproc_states" }
    Object.const_set(:PhronomyXprocModel, xproc_model)

    store = Phronomy::StateStore::ActiveRecord.new(model_class: PhronomyXprocModel)
    Phronomy.configure { |c| c.default_state_store = store }

    graph = Phronomy::Graph::StateGraph.new(StoreTestState)
    graph.add_node(:step1) { |s| {value: s.value + 10} }
    graph.add_node(:step2) { |s| {value: s.value + 1} }
    graph.set_entry_point(:step1)
    graph.add_edge(:step1, :step2)
    graph.add_edge(:step2, Phronomy::Graph::StateGraph::FINISH)
    app = graph.compile
    app.interrupt_before(:step2) { |_s| :halt }

    halted = app.invoke({value: 0}, config: {thread_id: "xproc-test"})
    expect(halted.current_nodes).to eq([:step2])
    expect(halted.halted_before).to be(true)
    expect(halted.value).to eq(10)

    # Confirm the record was physically written to the file DB.
    expect(PhronomyXprocModel.find_by(thread_id: "xproc-test")).not_to be_nil

    # --- Process 2: a real subprocess reads from the same file DB and resumes ---
    stdout, stderr, status = Open3.capture3(
      {"BUNDLE_GEMFILE" => File.join(gem_root, "Gemfile")},
      "bundle", "exec", "ruby", script_path,
      chdir: gem_root
    )
    expect(status.exitstatus).to eq(0),
      "Subprocess failed:\nSTDOUT: #{stdout}\nSTDERR: #{stderr}"

    result = JSON.parse(File.read(result_path))
    expect(result["value"]).to eq(11)
    expect(result["current_nodes"]).to be_empty
  ensure
    Phronomy.reset_configuration!
    Object.send(:remove_const, :PhronomyXprocModel) if Object.const_defined?(:PhronomyXprocModel)
    Object.send(:remove_const, :PhronomyXprocBase) if Object.const_defined?(:PhronomyXprocBase)
    db_file&.unlink
    result_file&.unlink
    script_file&.unlink
  end
end
