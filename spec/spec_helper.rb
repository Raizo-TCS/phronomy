# frozen_string_literal: true

# Coverage must be started before any application code is loaded.
if ENV["COVERAGE"]
  require "simplecov"
  require "simplecov-lcov"
  SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::LcovFormatter
  ])
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
    add_filter "/vendor/"
    minimum_coverage line: 85, branch: 75
  end
end

require "phronomy"

# Suppress rantly dot/SUCCESS output by default; set RANTLY_VERBOSE=1 to enable.
ENV["RANTLY_VERBOSE"] ||= "0"

# Load shared examples and other support files.
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Reduce EventLoop stop grace period to zero in tests so that
  # EventLoop.reset! / stop calls return immediately instead of
  # waiting up to 5s for the task to exit.
  config.before(:suite) do
    Phronomy.configure { |c| c.event_loop_stop_grace_seconds = 0 }
  end

  # Reset configuration between examples to prevent test pollution.
  # The EventLoop is intentionally NOT stopped here: since Phase 2, every
  # Agent#invoke goes through FSMSession + EventLoop. Stopping the EventLoop
  # after each test adds overhead per test. Tests that explicitly need a
  # fresh EventLoop must call Phronomy::EventLoop.reset! themselves.
  # run_via_event_loop and _invoke_via_fsm restart it lazily if needed.
  config.after(:each) do
    Phronomy.reset_runtime!
  end

  # Clean shutdown after the suite so that the EventLoop thread does not
  # prevent the process from exiting.
  config.after(:suite) do
    Phronomy::EventLoop.instance.stop(drain: false)
  rescue
    nil
  end
end
