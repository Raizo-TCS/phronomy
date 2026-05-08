# frozen_string_literal: true

module Phronomy
  module Memory
  end
end

require_relative "memory/base"
require_relative "memory/window_memory"
require_relative "memory/summary_memory"
require_relative "memory/semantic_memory"
require_relative "memory/composite_memory"
require_relative "memory/active_record_memory"
require_relative "memory/entity_memory"

# New architecture: Storage / Retrieval / Compression axes
require_relative "memory/storage"
require_relative "memory/storage/base"
require_relative "memory/storage/in_memory"
require_relative "memory/storage/active_record"
require_relative "memory/retrieval"
require_relative "memory/retrieval/base"
require_relative "memory/retrieval/recent"
require_relative "memory/retrieval/semantic"
require_relative "memory/compression"
require_relative "memory/compression/base"
require_relative "memory/compression/summary"
require_relative "memory/compression/tool_output_pruner"
require_relative "memory/conversation_manager"
