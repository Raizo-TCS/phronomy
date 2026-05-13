# frozen_string_literal: true

require_relative "graph/context"
require_relative "graph/state"
require_relative "graph/parallel_node"
require_relative "graph/workflow_runner"
require_relative "graph/state_graph"
require_relative "graph/compiled_graph"

module Phronomy
  module Graph
    # Raised when a parallel branch exceeds the wall-clock limit set via +timeout:+.
    class TimeoutError < Phronomy::Error; end
  end
end
