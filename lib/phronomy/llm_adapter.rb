# frozen_string_literal: true

module Phronomy
  # LLM domain operations and public request, response, usage and failure values.
  # A backend implements Base's protected hooks. SDK objects remain inside the
  # backend; AsyncClient executes the entire synchronous operation on a worker.
  # @api public
  module LLMAdapter
  end
end
