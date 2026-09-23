# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "ripper"

RSpec.describe "Agent default and one-shot composition (ADR-044)" do
  let(:project_root) { File.expand_path("../../..", __dir__) }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "default-composition", version: 1
      model "test-model"
    end
  end

  def isolated_ruby(source)
    stdout, stderr, status = Open3.capture3(
      {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
      RbConfig.ruby, "-rbundler/setup", "-I#{File.join(project_root, "lib")}",
      "-e", source, chdir: project_root
    )
    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  it "uses explicit Persistence before configuration without calling the default factory" do
    explicit = Phronomy::Persistence.in_memory
    configured = Phronomy::Persistence.in_memory
    Phronomy.configuration.persistence = configured
    expect(Phronomy::Agent::DefaultPersistence).not_to receive(:build)

    expect(agent_class.create(persistence: explicit).persistence).to equal(explicit)
    expect(Phronomy.configuration.persistence).to equal(configured)
  end

  it "uses configured Persistence without constructing a fallback" do
    configured = Phronomy::Persistence.in_memory
    Phronomy.configuration.persistence = configured
    expect(Phronomy::Agent::DefaultPersistence).not_to receive(:build)

    expect(agent_class.create.persistence).to equal(configured)
  end

  it "creates fresh defaults across instances and subclasses without changing configuration" do
    first = agent_class.create
    child = Class.new(agent_class) do
      agent_definition id: "default-composition-child", version: 1
    end
    second = child.create

    expect(first.persistence).to be_a(Phronomy::Persistence)
    expect(second.persistence).to be_a(Phronomy::Persistence)
    expect(first.persistence.backend).to be_a(Phronomy::Storage::Backends::InMemory)
    expect(first.persistence).not_to equal(second.persistence)
    expect(first.persistence.backend).not_to equal(second.persistence.backend)
    expect(Phronomy.configuration.persistence).to be_nil
  end

  it "keeps the construction binding across Runtime and configuration resets" do
    before = agent_class.create.persistence
    Phronomy.reset_runtime!
    after = agent_class.create.persistence

    expect(after).to be_a(Phronomy::Persistence)
    expect(after).not_to equal(before)
    expect(Phronomy.configuration.persistence).to be_nil
  end

  it "propagates a classified construction failure and permits a later retry for the same Agent identity" do
    failure = Phronomy::ConfigurationError.new("default unavailable")
    allow(Phronomy::Agent::DefaultPersistence).to receive(:build).and_raise(failure)
    expect { agent_class.create(agent_id: "retry-default") }.to raise_error { |error|
      expect(error).to equal(failure)
    }
    expect(agent_class.get("retry-default")).to be_nil

    allow(Phronomy::Agent::DefaultPersistence).to receive(:build).and_call_original
    expect(agent_class.create(agent_id: "retry-default").agent_id).to eq("retry-default")
  end

  it "preserves fail-closed ownership for an unclassified factory failure" do
    failure = IOError.new("default construction outcome unknown")
    allow(Phronomy::Agent::DefaultPersistence).to receive(:build).and_raise(failure)
    expect { agent_class.create(agent_id: "unknown-default") }.to raise_error { |error|
      expect(error).to equal(failure)
    }
    expect { agent_class.get("unknown-default") }
      .to raise_error(Phronomy::Error, /ownership requires durable recovery/)
    allow(Phronomy::Agent::DefaultPersistence).to receive(:build).and_call_original
    expect { agent_class.create(agent_id: "unknown-default") }
      .to raise_error(Phronomy::Error, /ownership requires durable recovery/)
  end

  it "constructs through a supplied factory without loading any concrete Persistence or Runtime" do
    isolated_ruby(<<~RUBY)
      require "phronomy/agent/lifecycle/default_persistence"
      calls = []
      factory = -> { calls << :create; Object.new }
      Phronomy::Agent::DefaultPersistence.install_factory(factory)
      abort "factory ran during binding" unless calls.empty?
      first = Phronomy::Agent::DefaultPersistence.build
      second = Phronomy::Agent::DefaultPersistence.build
      abort "factory not called separately" unless calls == [:create, :create]
      abort "default shared" if first.equal?(second)
      begin
        Phronomy::Agent::DefaultPersistence.install_factory(-> { :replacement })
        abort "boot binding replaced"
      rescue FrozenError
      end
      forbidden = $LOADED_FEATURES.grep(%r{/phronomy/(engine|runtime_composition|persistence|storage)/})
      abort "concrete dependencies loaded: \#{forbidden.inspect}" unless forbidden.empty?
    RUBY
  end

  [false, true].each do |preload_contract|
    it "preserves normal and eager loading without constructing defaults (preload: #{preload_contract})" do
      isolated_ruby(<<~RUBY)
        require "phronomy/agent/lifecycle/default_persistence" if #{preload_contract}
        previous_agent = Phronomy::Agent if #{preload_contract}
        require "phronomy"
        abort "Agent namespace replaced" if previous_agent && !previous_agent.equal?(Phronomy::Agent)
        method = Phronomy::Agent.method(:run_once)
        expected = [[:keyreq, :definition], [:keyreq, :input], [:key, :context],
          [:key, :knowledge], [:key, :on_event], [:keyrest, :invoke_options], [:block, :event_block]]
        abort "run_once parameters changed" unless method.parameters == expected
        abort "run_once still defined in lower API" unless method.source_location.first.end_with?("/agent/composition/run_once.rb")
        original_event = Phronomy::Agent::StreamEvent
        2.times do
          require "phronomy"
          Zeitwerk::Loader.eager_load_all
          abort "run_once replaced" unless Phronomy::Agent.method(:run_once) == method
          abort "event identity changed" unless Phronomy::Agent::StreamEvent.equal?(original_event)
          abort "event extension missing or repeated" unless Phronomy::Agent::Base.ancestors.count(Phronomy::Agent::AsyncEventApi) == 1
        end
        abort "new composition namespace" if Phronomy::Agent.const_defined?(:Composition, false)
        abort "global configuration created" if Phronomy.instance_variable_get(:@configuration)
        abort "Runtime started" if Phronomy::Runtime.default_if_initialized_for_test
        abort "RSpec loaded" if defined?(RSpec)
        Phronomy::Agent::DefaultPersistence.singleton_class.send(:define_method, :build) { raise "unexpected fallback" }
        persistence = Phronomy::Persistence.in_memory
        klass = Class.new(Phronomy::Agent::Base) { agent_definition id: "preloaded-default", version: 1 }
        agent = klass.create(persistence: persistence)
        abort "explicit override lost" unless agent.persistence.equal?(persistence)
        Phronomy.reset_runtime!
      RUBY
    end
  end

  it "keeps concrete Persistence selection and composition loading out of Agent execution and API" do
    paths = ["lib/phronomy/agent/base.rb", "lib/phronomy/agent/api/agent.rb",
      "lib/phronomy/agent/lifecycle/default_persistence.rb"]
    paths.each do |path|
      tokens = Ripper.lex(File.read(File.join(project_root, path)))
      constants = tokens.filter_map { |_, type, token, _| token if type == :on_const }
      expect(constants).not_to include("Persistence", "InMemory")
      requires = File.read(File.join(project_root, path)).scan(/^\s*require(?:_relative)?\s+["']([^"']+)/).flatten
      expect(requires.grep(/runtime_composition|composition\/run_once|persistence\/api/)).to be_empty
    end
  end

  describe "run_once" do
    def fake_chat
      tokens = double("Tokens", input: 1, output: 1, cache_read: 0, cache_write: 0,
        to_h: {"input" => 1, "output" => 1, "cached" => 0, "cache_creation" => 0})
      response = double("Response", role: :assistant, content: "answer", tool_calls: nil, tokens: tokens, tool_call?: false)
      chat = double("Chat", messages: [], last_message: response)
      allow(chat).to receive(:with_instructions).and_return(chat)
      allow(chat).to receive(:with_tools).and_return(chat)
      allow(chat).to receive(:cancellation_token=)
      allow(chat).to receive(:on_tool_call)
      allow(chat).to receive(:after_message)
      allow(chat).to receive(:on_tool_result)
      allow(chat).to receive(:ask).and_return(response)
      chat
    end

    it "creates isolated storage every time even with a configured shared Persistence" do
      configured = Phronomy::Persistence.in_memory
      Phronomy.configuration.persistence = configured
      # run_once does not consume Base's fallback; it owns explicit composition.
      expect(Phronomy::Agent::DefaultPersistence).not_to receive(:build)
      observed = []
      agent_class.define_method(:invoke) do |input, **options|
        observed << {persistence: persistence, input: input, options: options}
        :unchanged_result
      end
      marker = Object.new
      2.times do
        expect(Phronomy::Agent.run_once(definition: agent_class, input: marker, custom: marker))
          .to eq(:unchanged_result)
      end

      expect(observed.map { |o| o[:persistence] }.uniq.length).to eq(2)
      observed.each do |o|
        expect(o[:persistence]).not_to equal(configured)
        expect(o[:input]).to equal(marker)
        expect(o[:options]).to eq(custom: marker)
      end
      expect(Phronomy.configuration.persistence).to equal(configured)
    end

    [:keyword, :block].each do |listener_form|
      it "preserves creation context, Knowledge and #{listener_form} event delivery through real Agent invocation" do
        allow(RubyLLM).to receive(:chat) { fake_chat }
        created = nil
        allow(agent_class).to receive(:create).and_wrap_original do |original, **options, &block|
          created = original.call(**options, &block)
        end
        events = []
        listener = ->(event) { events << event }
        args = {definition: agent_class, input: "hello",
                context: [{role: :user, content: "prior context"}], knowledge: ["Policy: be concise."]}
        result = if listener_form == :keyword
          Phronomy::Agent.run_once(**args, on_event: listener)
        else
          Phronomy::Agent.run_once(**args, &listener)
        end
        expect(result[:output]).to eq("answer")
        expect(events.map(&:type)).to include(:done)
        records = created.journal_projection.context_records
        texts = records.filter_map { |record| created.persistence.contents.fetch_text(record.content_ref) if record.content_ref }
        expect(texts).to include("prior context", "Policy: be concise.")
      end
    end

    it "rejects two listeners before creating any one-shot storage or Agent" do
      expect(Phronomy::Persistence).not_to receive(:in_memory)
      expect(agent_class).not_to receive(:create)
      expect {
        Phronomy::Agent.run_once(definition: agent_class, input: "hello", on_event: ->(_) {}) { |_| }
      }.to raise_error(ArgumentError, "Provide either on_event: or a block, not both")
    end

    it "propagates an invocation failure without replacing the original exception" do
      failure = IOError.new("one-shot failed")
      agent_class.define_method(:invoke) { |*| raise failure }
      expect { Phronomy::Agent.run_once(definition: agent_class, input: "hello") }.to raise_error { |error|
        expect(error).to equal(failure)
      }
    end
  end
end
