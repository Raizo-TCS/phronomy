# frozen_string_literal: true

require_relative "runtime_shutdown_error"

module Phronomy
  class RuntimeShutdownReentrancyError < RuntimeShutdownError; end
end
