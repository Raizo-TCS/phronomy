# frozen_string_literal: true

# Global configuration access, replacement, and scoped overrides.
# Explicitly loaded by the application entry point; not a common definition.
module Phronomy
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def with_configuration
      original = @configuration&.dup
      yield configuration
    ensure
      @configuration = original
    end
  end
end
