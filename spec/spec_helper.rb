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
    skip "/spec/"
    skip "/vendor/"
    skip "/lib/phronomy/testing/persistence_contract"
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

  # Keep test teardown bounded. The timeout is a maximum; a normally idle
  # Runtime-owned EventLoop stops immediately after receiving STOP.
  config.before(:suite) do
    Phronomy.configure { |c| c.event_loop_stop_grace_seconds = 1 }
  end

  # Runtime shutdown is irreversible. Each example receives a fresh default
  # Runtime on first use and teardown shuts it down completely.
  # If cleanup is incomplete (dispatcher still alive after timeout), force-clear
  # the singleton so subsequent examples start with a fresh Runtime.
  config.after(:each) do
    Phronomy.reset_runtime!
  rescue Phronomy::RuntimeShutdownError
    # Force-clear even if cleanup was incomplete. Orphaned threads from the
    # previous example may remain, but subsequent examples get a fresh Runtime.
    Phronomy::Runtime.restore_default_for_test(nil)
    Phronomy.reset_configuration!
  end

  # after(:each) normally leaves no default Runtime, but keep suite teardown
  # defensive for examples that fail before their example hook completes.
  config.after(:suite) do
    Phronomy.reset_runtime!
  rescue
    nil
  end
end
