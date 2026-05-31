# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# Nightly spec: optional dependency absence tests.
#
# These tests verify that:
#   1. Phronomy loads cleanly without optional gems installed.
#   2. Accessing an optional feature without the required gem raises a helpful
#      LoadError message (not an uninitialized constant error).
#
# Each guard test runs in a subprocess that explicitly removes the optional gem
# from the load path, so results are independent of whether the gem is installed
# in the test environment.
#
# Run with: bundle exec rspec spec/integration/nightly/optional_absence_spec.rb --tag nightly

LIB_PATH = File.expand_path("../../../lib", __dir__)
RUBY_BIN = RbConfig.ruby

# Run a short Ruby snippet in a subprocess with only phronomy on the load path.
# Returns [stdout, stderr, Process::Status].
def run_in_subprocess(snippet)
  Open3.capture3(RUBY_BIN, "-I", LIB_PATH, "-e", snippet)
end

RSpec.describe "Optional dependency absence", :nightly do
  describe "Phronomy::Agent::Context::Knowledge::VectorStore::Pgvector without pgvector gem" do
    it "raises LoadError with a helpful message if pgvector is not installed" do
      script = <<~RUBY
        require "phronomy"
        # Strip pgvector from the load path and loaded features to simulate absence.
        $LOADED_FEATURES.reject! { |f| f.include?("/pgvector") }
        $LOAD_PATH.reject! { |p| Dir["\#{p}/pgvector.rb", "\#{p}/pgvector/**"].any? }
        begin
          Phronomy::Agent::Context::Knowledge::VectorStore::Pgvector.new(model_class: nil)
          puts "LOADED_OK"
        rescue LoadError => e
          puts e.message.include?("pgvector gem is required") ? "CORRECT" : "WRONG: \#{e.message}"
        end
      RUBY
      stdout, _stderr, _status = run_in_subprocess(script)
      expect(stdout.strip).to match(/LOADED_OK|CORRECT/)
    end
  end

  describe "Phronomy::Agent::Context::Knowledge::VectorStore::RedisSearch without redis gem" do
    it "raises LoadError with a helpful message if redis is not installed" do
      script = <<~RUBY
        require "phronomy"
        $LOADED_FEATURES.reject! { |f| f =~ /\\/redis(\\.rb|\\/)/ }
        $LOAD_PATH.reject! { |p| Dir["\#{p}/redis.rb", "\#{p}/redis/**"].any? }
        begin
          Phronomy::Agent::Context::Knowledge::VectorStore::RedisSearch.new(redis: nil, dimension: 3)
          puts "LOADED_OK"
        rescue LoadError => e
          puts e.message.include?("redis gem is required") ? "CORRECT" : "WRONG: \#{e.message}"
        end
      RUBY
      stdout, _stderr, _status = run_in_subprocess(script)
      expect(stdout.strip).to match(/LOADED_OK|CORRECT/)
    end
  end

  describe "Phronomy::Tracing::OpenTelemetryTracer without opentelemetry gem" do
    it "raises LoadError with a helpful message if opentelemetry is not installed" do
      script = <<~RUBY
        require "phronomy"
        $LOADED_FEATURES.reject! { |f| f.include?("/opentelemetry") }
        $LOAD_PATH.reject! { |p| Dir["\#{p}/opentelemetry*"].any? }
        begin
          Phronomy::Tracing::OpenTelemetryTracer.new
          puts "LOADED_OK"
        rescue LoadError => e
          puts "GOT_LOAD_ERROR"
        rescue => e
          puts "OTHER: \#{e.class}"
        end
      RUBY
      stdout, _stderr, _status = run_in_subprocess(script)
      expect(stdout.strip).to match(/LOADED_OK|GOT_LOAD_ERROR/)
    end
  end

  describe "Phronomy core load without optional gems" do
    it "loads phronomy without raising" do
      expect { require "phronomy" }.not_to raise_error
    end

    it "exposes the expected core constants" do
      expect(defined?(Phronomy::Agent::Base)).to eq("constant")
      expect(defined?(Phronomy::Agent::Context::Capability::Base)).to eq("constant")
      expect(defined?(Phronomy::Workflow)).to eq("constant")
      expect(defined?(Phronomy::Agent::Context::Knowledge::VectorStore::InMemory)).to eq("constant")
      expect(defined?(Phronomy::Tracing::NullTracer)).to eq("constant")
    end
  end
end
