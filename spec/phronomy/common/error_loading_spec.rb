# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Common base exception loading" do
  let(:project_root) { File.expand_path("../../..", __dir__) }

  def run_isolated_ruby(source, standalone: false)
    Open3.capture3(
      {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
      RbConfig.ruby,
      standalone ? "--disable-gems" : "-rbundler/setup",
      "-I#{File.join(project_root, "lib")}",
      "-e",
      source,
      chdir: project_root
    )
  end

  it "loads the common base without initializing the framework or its gem dependencies" do
    source = <<~RUBY
      require "phronomy/common/error"
      abort "unexpected framework definitions" unless Phronomy.constants(false) == [:Error]
      abort "incorrect base" unless Phronomy::Error.superclass == StandardError
      abort "incorrect name" unless Phronomy::Error.name == "Phronomy::Error"
    RUBY

    stdout, stderr, status = run_isolated_ruby(source, standalone: true)

    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  [false, true].each do |preload_base|
    it "preserves exception identity, inheritance, and rescue through eager loading (preload: #{preload_base})" do
      source = <<~RUBY
        require "phronomy/common/error" if #{preload_base}
        previous_base = Phronomy::Error if #{preload_base}
        require "phronomy"
        base = Phronomy::Error
        abort "base replaced by entry point" if previous_base && !base.equal?(previous_base)
        abort "incorrect base" unless base.superclass == StandardError
        abort "incorrect name" unless base.name == "Phronomy::Error"

        hierarchies = {
          "ParseError" => "Error",
          "RateLimitError" => "TransportError",
          "SchedulerReentrancyError" => "EventLoopReentrancyError",
          "RuntimeShutdownReentrancyError" => "RuntimeShutdownError",
          "AgentBusyError" => "Error",
          "Storage::ConflictError" => "Error",
          "Storage::ActiveExecutionConflictError" => "Storage::ConflictError",
          "ExecutionCancellationError" => "CancellationError"
        }

        2.times do |phase|
          Zeitwerk::Loader.eager_load_all if phase == 1
          abort "base replaced by eager loading" unless Phronomy::Error.equal?(base)
          abort "unexpected Common namespace" if Phronomy.const_defined?(:Common, false)
          hierarchies.each do |name, parent|
            klass = Phronomy.const_get(name)
            abort "incorrect superclass for \#{name}" unless klass.superclass == Phronomy.const_get(parent)
          end

          error = Phronomy::Storage::ConflictError.new("conflict")
          caught = begin
            raise error
          rescue Phronomy::Error => rescued
            rescued
          end
          abort "domain error was not preserved by rescue" unless caught.equal?(error)
        end
      RUBY

      stdout, stderr, status = run_isolated_ruby(source)

      expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
    end
  end
end
