# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "ripper"

RSpec.describe "Responsibility-based source layout" do
  let(:project_root) { File.expand_path("../..", __dir__) }
  let(:library_root) { File.join(project_root, "lib/phronomy") }

  def isolated_ruby(source)
    Open3.capture3(
      {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
      RbConfig.ruby, "-rbundler/setup", "-I#{File.join(project_root, "lib")}",
      "-e", source, chdir: project_root
    )
  end

  it "reserves the direct root for the version and documented namespace loading files" do
    expect(Dir.glob(File.join(library_root, "*.rb")).map { |path| File.basename(path) })
      .to contain_exactly(
        "filter.rb", "llm_adapter.rb", "output_parser.rb", "testing.rb",
        "tool.rb", "tracing.rb", "vector_store.rb", "version.rb"
      )

    Dir.glob(File.join(library_root, "*.rb")).each do |path|
      syntax = Ripper.sexp(File.read(path))
      expect(syntax).not_to be_nil
      # Namespace files cannot regain method bodies or executable class implementations.
      expect(syntax.flatten).not_to include(:def, :defs, :class)
    end
  end

  it "forbids implementation files from requiring the application entry point" do
    entry = File.join(project_root, "lib/phronomy.rb")
    # This is an existing, separately documented public test-suite entry point
    # for external backend authors, excluded from production autoloading.
    public_test_entry = File.join(library_root, "testing/persistence_contract.rb")
    implementation_files = Dir.glob(File.join(library_root, "**/*.rb")) - [public_test_entry]
    offenders = implementation_files.flat_map do |path|
      File.read(path).scan(/^\s*(require(?:_relative)?)\s*(?:\(\s*)?["']([^"']+)["']/).filter_map do |kind, target|
        base = (kind == "require_relative") ? File.dirname(path) : File.join(project_root, "lib")
        resolved = File.expand_path(target.delete_suffix(".rb") + ".rb", base)
        path if resolved == entry
      end
    end

    expect(offenders).to be_empty
  end

  it "loads common values and exceptions without initializing feature implementations" do
    stdout, stderr, status = isolated_ruby(<<~RUBY)
      require "phronomy/common/configuration_error"
      require "phronomy/common/values/immutable"
      # Bundler reads the gemspec's version file before executing this process.
      expected = %i[VERSION Error ConfigurationError CanonicalJSON Values]
      abort "feature initialized by common definitions" unless Phronomy.constants(false).sort == expected.sort
      abort "incorrect exception hierarchy" unless Phronomy::ConfigurationError.superclass == Phronomy::Error
      abort "RSpec loaded by production definitions" if defined?(RSpec)

      opaque = Object.new
      original = { ["key"] => ["value", opaque] }
      copy = Phronomy::Values::Immutable.copy(original)
      abort "mutable common value" unless copy.frozen? && copy.keys.first.frozen? && copy.values.first.frozen?
      abort "string alias retained" if copy.values.first.first.equal?(original.values.first.first)
      abort "opaque value identity lost" unless copy.values.first.last.equal?(opaque)
      abort "input mutated" if original.frozen? || original.values.first.frozen?
      abort "JSON normalization changed" unless Phronomy::CanonicalJSON.dump({"b" => 2, "a" => 1}) == '{"a":1,"b":2}'
    RUBY

    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  it "keeps concrete defaults and Runtime coordination outside configuration definitions" do
    configuration_files = Dir.glob(File.join(library_root, "configuration/**/*.rb"))
    concrete_references = configuration_files.select do |path|
      Ripper.lex(File.read(path)).any? do |_, type, token, _|
        type == :on_const && %w[Runtime LLMAdapter Tracing].include?(token)
      end
    end
    expect(concrete_references).to be_empty

    stdout, stderr, status = isolated_ruby(<<~RUBY)
      Dir.glob("lib/phronomy/configuration/**/*.rb").sort.each { |path| require File.expand_path(path) }
      abort "Runtime lifecycle exposed by configuration" if Phronomy.respond_to?(:reset_runtime!)
      unexpected = $LOADED_FEATURES.grep(%r{/phronomy/(engine|runtime_composition|llm_adapter|tracing)/})
      abort "Feature implementation loaded by configuration: \#{unexpected.inspect}" unless unexpected.empty?

      require "phronomy"
      abort "application lifecycle API missing" unless Phronomy.respond_to?(:reset_runtime!)
      abort "configuration API missing" unless Phronomy.respond_to?(:configuration)
      Zeitwerk::Loader.eager_load_all
      abort "unexpected public composition namespace" if Phronomy.const_defined?(:RuntimeComposition, false)
    RUBY

    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  it "constructs settings using supplied factories without concrete feature implementations" do
    stdout, stderr, status = isolated_ruby(<<~RUBY)
      require "phronomy/configuration/configuration"
      calls = []
      Phronomy::Configuration.install_default_factories(
        tracer: -> { calls << :tracer; Object.new },
        llm_adapter: -> { calls << :llm_adapter; Object.new }
      )
      abort "factories called during binding" unless calls.empty?
      first = Phronomy::Configuration.new
      second = Class.new(Phronomy::Configuration).new
      abort "factory order or count changed" unless calls == [:tracer, :llm_adapter, :tracer, :llm_adapter]
      abort "tracer shared across configurations" if first.tracer.equal?(second.tracer)
      abort "adapter shared across configurations" if first.llm_adapter.equal?(second.llm_adapter)
      abort "scalar defaults changed" unless first.recursion_limit == 25 && second.trace_pii == false
      unexpected = $LOADED_FEATURES.grep(%r{/phronomy/(engine|runtime_composition|llm_adapter|tracing)/})
      abort "feature implementation loaded: \#{unexpected.inspect}" unless unexpected.empty?
    RUBY

    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  it "binds defaults without creating global settings or starting the default Runtime" do
    stdout, stderr, status = isolated_ruby(<<~RUBY)
      require "phronomy"
      abort "global settings created during require" if Phronomy.instance_variable_get(:@configuration)
      abort "Runtime started during require" if Phronomy::Runtime.default_if_initialized_for_test
      config = Phronomy::Configuration.new
      abort "default adapter changed" unless config.llm_adapter.instance_of?(Phronomy::LLMAdapter::RubyLLM)
      abort "default tracer changed" unless config.tracer.instance_of?(Phronomy::Tracing::NullTracer)
      abort "standalone settings installed globally" if Phronomy.instance_variable_get(:@configuration)
      require "phronomy"
      Zeitwerk::Loader.eager_load_all
      abort "global settings created by eager loading" if Phronomy.instance_variable_get(:@configuration)
      abort "Runtime started by configuration or eager loading" if Phronomy::Runtime.default_if_initialized_for_test
    RUBY

    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  [
    "Phronomy::Workflow::PhaseMachineBuilder",
    "Phronomy::Workflow::Persistence::Codec",
    "Phronomy::Agent::ContextPolicy",
    "Phronomy::Agent",
    "Phronomy::Persistence",
    "Phronomy::AgentBusyError"
  ].each do |first_constant|
    it "preserves public identities and lifecycle extensions when #{first_constant} is accessed first" do
      stdout, stderr, status = isolated_ruby(<<~RUBY)
        require "phronomy/common/configuration_error"
        require "phronomy/common/values/immutable"
        previous_error = Phronomy::Error
        previous_values = Phronomy::Values::Immutable
        require "phronomy"
        #{first_constant}

        names = %w[Workflow WorkflowContext WorkflowRunner Agent Persistence Execution Event TokenUsage]
        originals = names.to_h { |name| [name, Phronomy.const_get(name)] }
        abort "Workflow ceased to be a class" unless Phronomy::Workflow.is_a?(Class)
        abort "Agent ceased to be a module" unless Phronomy::Agent.instance_of?(Module)
        abort "Workflow recovery not installed during require" unless Phronomy::WorkflowRunner.ancestors.count(Phronomy::WorkflowRecovery) == 1
        abort "Agent event extension missing" unless Phronomy::Agent::Base.ancestors.count(Phronomy::Agent::AsyncEventApi) == 1
        abort "common error replaced" unless Phronomy::Error.equal?(previous_error)
        abort "common values replaced" unless Phronomy::Values::Immutable.equal?(previous_values)
        abort "RSpec loaded during normal require" if defined?(RSpec)

        2.times { Zeitwerk::Loader.eager_load_all }
        originals.each do |name, original|
          current = Phronomy.const_get(name)
          abort "identity changed for \#{name}" unless current.equal?(original)
          abort "canonical name changed for \#{name}" unless current.name == "Phronomy::\#{name}"
        end
        abort "RSpec loaded during eager load" if defined?(RSpec)
      RUBY

      expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
    end
  end
end
