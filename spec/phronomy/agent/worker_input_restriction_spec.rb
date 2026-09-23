# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "ripper"

RSpec.describe "Worker input restriction ownership (ADR-045)" do
  # This inventory records the pre-marker rejection set. Keeping concrete types
  # in regression tests does not put the list back into production selection.
  restricted_types = [
    Phronomy::Agent::Base,
    Phronomy::Agent::AgentRoot,
    Phronomy::Agent::AgentExecution,
    Phronomy::Agent::AgentInvocation,
    Phronomy::Agent::ToolInvocation,
    Phronomy::Agent::JournalProjection,
    Phronomy::Agent::ExecutionCoordinator,
    Phronomy::Agent::Context::Capability::Base,
    Phronomy::Workflow,
    Phronomy::WorkflowRunner,
    Phronomy::WorkflowContext,
    Phronomy::Runtime,
    Phronomy::TaskResult,
    Phronomy::EventLoop,
    Phronomy::FSMSession,
    Phronomy::FSMSession::EventSink,
    Phronomy::Concurrency::CancellationToken,
    Phronomy::Concurrency::OffloadPool
  ]

  let(:evaluator) { Phronomy::Agent::ToolInvocation }
  let(:project_root) { File.expand_path("../../..", __dir__) }

  restricted_types.each do |type|
    [false, true].each do |subclass|
      it "rejects #{type} in nested values and handles, including frozen instances (subclass: #{subclass})" do
        # Classification must not depend on initialization or a running Runtime.
        klass = type.is_a?(Class) ? type : Class.new { include type }
        klass = Class.new(klass) if subclass
        [false, true].each do |frozen|
          value = klass.allocate
          value.freeze if frozen
          [value, {value => "key"}, {nested: {item: value}}, {nested: ["ok", [value]]}].each do |data|
            expect { evaluator.send(:immutable_command_copy, data) }
              .to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
          end
          %w[approval_policy approval_facts requires_approval].each do |name|
            expect { evaluator.send(:safe_behavior_handle, value, name) }
              .to raise_error(Phronomy::ConfigurationError, /#{name} must not be a Phronomy-managed/)
          end
        end
      end
    end
  end

  it "keeps opaque values and application callables by identity without inspecting captured state" do
    live = Phronomy::Workflow.allocate
    opaque = Struct.new(:captured).new(live)
    callable = -> { live }
    runnable = Class.new { include Phronomy::Runnable }.new
    outcome = Phronomy::TaskResult::Outcome.new(index: 0, status: :ok, value: "value", error: nil)
    values = [opaque, callable, runnable, outcome, Object.new, Phronomy::Workflow, Phronomy::WorkflowContext]

    values.each do |value|
      copy = evaluator.send(:immutable_command_copy, {nested: [value]})
      expect(copy[:nested].first).to equal(value)
      expect(evaluator.send(:safe_behavior_handle, value, "approval_policy")).to equal(value)
    end
    [nil, false, true].each do |value|
      expect(evaluator.send(:safe_behavior_handle, value, "requires_approval")).to equal(value)
    end
  end

  it "rejects a previously unknown marked type without adding it to the evaluator" do
    value = Class.new { include Phronomy::Concurrency::WorkerInputRestricted }.new
    expect { evaluator.send(:immutable_command_copy, {nested: [value]}) }
      .to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
    expect { evaluator.send(:safe_behavior_handle, value, "approval_policy") }
      .to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
  end

  describe "authorization command capture" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "restricted-worker-input", version: 1

        def initialize
          @agent_id = "restricted-worker-input"
        end
      end
    end
    let(:tool) do
      Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "restricted_input_tool"
        description "Worker input boundary test"

        def execute
          "ok"
        end
      end.new
    end

    def invocation(policy: nil, context: {})
      evaluator.new(execution_id: "execution-1", agent: agent_class.new, tool: tool,
        tool_call: Struct.new(:id, :name, :arguments).new("call-1", "restricted_input_tool", {}),
        config: {}, approval_policy: policy, approval_context: context).tap(&:validate!)
    end

    [Phronomy::Workflow, Phronomy::WorkflowRunner, Phronomy::WorkflowContext].each do |type|
      [:approval_context, :approval_policy, :approval_facts, :requires_approval].each do |route|
        it "rejects #{type} through #{route} before submitting a worker command" do
          klass = type.is_a?(Class) ? type : Class.new { include type }
          value = klass.allocate.freeze
          inv = case route
          when :approval_context then invocation(context: {nested: [value]})
          when :approval_policy then invocation(policy: value)
          when :approval_facts
            allow(tool.class).to receive(:approval_facts).and_return(value)
            invocation
          when :requires_approval
            allow(tool).to receive(:requires_approval).and_return(value)
            invocation
          end
          expect { inv.send(:authorization_command) }
            .to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
        end
      end
    end

    it "rejects marked values returned from an application facts callable" do
      value = Class.new { include Phronomy::WorkflowContext }.new
      allow(tool.class).to receive(:approval_facts).and_return(->(*) { {nested: [value]} })
      command = invocation.send(:authorization_command)
      expect { evaluator.send(:evaluate_authorization_command, command) }
        .to raise_error(Phronomy::ConfigurationError, /Phronomy-managed live domain object/)
    end
  end

  [false, true].each do |preload|
    it "preserves normal/preloaded/eager identity without starting Runtime (preload: #{preload})" do
      source = <<~RUBY
        require "phronomy/engine/concurrency/worker_input_restricted" if #{preload}
        original = Phronomy::Concurrency::WorkerInputRestricted if #{preload}
        require "phronomy"
        marker = Phronomy::Concurrency::WorkerInputRestricted
        abort "identity changed" if original && !original.equal?(marker)
        targets = [#{restricted_types.map(&:name).join(", ")}]
        2.times do
          require "phronomy"
          Zeitwerk::Loader.eager_load_all
          abort "marker replaced" unless Phronomy::Concurrency::WorkerInputRestricted.equal?(marker)
          abort "marker missing or repeated" unless targets.all? { |type| type.ancestors.count(marker) == 1 }
        end
        abort "marker defines behavior" unless marker.instance_methods(false).empty?
        abort "configuration constructed" if Phronomy.instance_variable_get(:@configuration)
        abort "Runtime started" if Phronomy::Runtime.default_if_initialized_for_test
      RUBY
      stdout, stderr, status = Open3.capture3(
        {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
        RbConfig.ruby, "-rbundler/setup", "-I#{File.join(project_root, "lib")}",
        "-e", source, chdir: project_root
      )
      expect(status).to be_success, -> { "#{stdout}\n#{stderr}" }
    end
  end

  it "loads the methodless marker alone without Agent, Workflow or runtime implementation" do
    source = <<~RUBY
      require "phronomy/engine/concurrency/worker_input_restricted"
      marker = Phronomy::Concurrency::WorkerInputRestricted
      abort "instance behavior" unless marker.instance_methods(false).empty?
      abort "singleton behavior" unless marker.singleton_methods(false).empty?
      abort "unexpected framework constants" unless Phronomy.constants(false) == [:Concurrency]
      abort "unexpected concurrency constants" unless Phronomy::Concurrency.constants(false) == [:WorkerInputRestricted]
      loaded = $LOADED_FEATURES.grep(%r{/phronomy/})
      abort loaded.inspect unless loaded.length == 1
    RUBY
    stdout, stderr, status = Open3.capture3(
      {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
      RbConfig.ruby, "--disable-gems", "-I#{File.join(project_root, "lib")}", "-e", source
    )
    expect(status).to be_success, -> { "#{stdout}\n#{stderr}" }
  end

  it "keeps Workflow constant selection out of Agent source and feature knowledge out of the marker" do
    Dir[File.join(project_root, "lib/phronomy/agent/**/*.rb")].each do |path|
      constants = Ripper.lex(File.read(path)).filter_map { |_, type, token, _| token if type == :on_const }
      expect(constants).not_to include("Workflow", "WorkflowRunner", "WorkflowContext")
    end
    path = File.join(project_root, "lib/phronomy/engine/concurrency/worker_input_restricted.rb")
    source = File.read(path)
    constants = Ripper.lex(source).filter_map { |_, type, token, _| token if type == :on_const }
    expect(constants.uniq).to match_array(%w[Phronomy Concurrency WorkerInputRestricted])
    expect(source).not_to match(/^\s*require(?:_relative)?\s/)
  end
end
