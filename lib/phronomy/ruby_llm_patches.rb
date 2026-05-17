# frozen_string_literal: true

# Patches for upstream ruby_llm bugs that have not yet been released.
# Remove each patch once the fix is available in a published gem version.

module RubyLLM
  module Streaming
    private

    # Upstream ruby_llm <= 1.15.0 assumes the SSE error chunk always has two
    # lines ("event: error\ndata: {...}") and uses a fixed index [1], which
    # raises NoMethodError when some providers (e.g. Qwen) return a single-line
    # chunk ("data: {...}").  This patch finds the data line by content instead.
    def handle_error_chunk(chunk, env)
      data_line = chunk.split("\n").find { |l| l.start_with?("data: ") } || chunk.split("\n")[0]
      error_data = data_line.delete_prefix("data: ")
      parse_error_from_json(error_data, env, "Failed to parse error chunk")
    end
  end
end
