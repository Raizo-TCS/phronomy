# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in phronomy.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "webrick", "~> 1.8"

gem "standard", "~> 1.3"

# OpenTelemetry SDK for tracer adapter tests (not required at runtime)
gem "opentelemetry-sdk", require: false

# HTTP stubbing for LangfuseTracer unit tests
gem "webmock", require: false

# ActiveRecord + SQLite3 for real-DB unit tests
gem "activerecord", "~> 7.1"
gem "sqlite3", "~> 2.0"

# ActiveJob for async memory write tests
gem "activejob", "~> 7.1"

# YARD for API documentation generation
gem "yard", require: false
