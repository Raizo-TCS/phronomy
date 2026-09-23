# frozen_string_literal: true

# Application lifecycle coordination across Runtime and global configuration.
# Explicitly loaded by the application entry point; not an Engine primitive.
module Phronomy
  class << self
    def reset_runtime!(timeout: configuration.event_loop_stop_grace_seconds)
      previous_grace = @configuration&.event_loop_stop_grace_seconds
      result = Runtime.reset_default!(timeout: timeout)

      new_configuration = Configuration.new
      if previous_grace
        new_configuration.event_loop_stop_grace_seconds = previous_grace
      end
      @configuration = new_configuration
      result
    end
  end
end
