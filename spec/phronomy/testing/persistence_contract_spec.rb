# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Persistence contract test support" do
  project_root = File.expand_path("../../..", __dir__)

  def run_isolated_ruby(project_root, source)
    Open3.capture3(
      {"COVERAGE" => nil},
      RbConfig.ruby,
      "-rbundler/setup",
      "-I#{File.join(project_root, "lib")}",
      "-e",
      source,
      chdir: project_root
    )
  end

  it "does not load RSpec through ordinary require or production eager-load" do
    source = <<~RUBY
      require "phronomy"
      abort "RSpec loaded by require phronomy" if defined?(RSpec)

      Zeitwerk::Loader.eager_load_all
      abort "RSpec loaded by production eager-load" if defined?(RSpec)
    RUBY

    stdout, stderr, status = run_isolated_ruby(project_root, source)

    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  it "loads and executes the complete contract suite through the public entry point" do
    source = <<~RUBY
      require "phronomy/testing/persistence_contract"

      abort "RSpec was not loaded" unless defined?(RSpec)
      abort "contract namespace missing" unless defined?(Phronomy::Testing::PersistenceContract)

      RSpec.describe "external Persistence contract smoke" do
        let(:persistence) { Phronomy::Persistence::InMemory.new }

        it_behaves_like "a persistence content store"
        it_behaves_like "an Agent repository"
        it_behaves_like "a Journal repository"
        it_behaves_like "an Execution repository"
        it_behaves_like "a workflow state repository"
        it_behaves_like "a Persistence backend"
      end

      exit RSpec::Core::Runner.run(["--format", "progress"])
    RUBY

    stdout, stderr, status = run_isolated_ruby(project_root, source)

    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end
end
