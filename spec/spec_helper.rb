# frozen_string_literal: true

# Coverage must be started before any application code is loaded.
if ENV["COVERAGE"]
  require "simplecov"
  require "simplecov-lcov"
  SimpleCov::Formatter::LcovFormatter.config.report_with_test_name = false
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

  # Reset all Phronomy runtime state between examples to prevent test pollution.
  # This stops any running EventLoop thread and reinitialises configuration.
  config.after(:each) do
    Phronomy.reset_runtime!
  end
end
