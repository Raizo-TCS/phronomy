# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in phronomy.gemspec
gemspec

gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "webrick", "~> 1.8"
gem "ostruct"  # removed from Ruby stdlib in Ruby 3.5+ / JRuby 10 (Ruby 4.0)
gem "csv"      # removed from Ruby stdlib in Ruby 3.4+
gem "base64"   # removed from Ruby stdlib in Ruby 3.4+

group :lint do
  gem "irb"
  gem "standard", "~> 1.3"
end

# OpenTelemetry SDK for tracer adapter tests (not required at runtime)
gem "opentelemetry-sdk", require: false

# HTTP stubbing for LangfuseTracer unit tests
gem "webmock", require: false

# ActiveRecord + SQLite3 + ActiveJob (CRuby only; C extensions not available on JRuby)
group :crb do
  gem "activerecord", "~> 7.1"
  gem "sqlite3", "~> 2.0"
  gem "activejob", "~> 7.1"
end

# YARD for API documentation generation
gem "yard", require: false
