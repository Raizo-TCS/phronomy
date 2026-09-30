# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RBS gem packaging" do
  it "includes the public signatures in the gem file list" do
    gemspec_path = File.expand_path("../../phronomy.gemspec", __dir__)
    specification = Gem::Specification.load(gemspec_path)

    expect(specification).not_to be_nil
    expect(specification.files).to include(
      "sig/phronomy.rbs",
      "sig/phronomy/runtime_composition/configuration.rbs",
      "sig/phronomy/execution/invocation_context.rbs",
      "sig/phronomy/execution/concurrency/cancellation_token.rbs",
      "sig/phronomy/execution/errors.rbs",
      "sig/phronomy/execution/task_result.rbs",
      "sig/phronomy/execution/control_protocols.rbs",
      "sig/phronomy/execution/concurrency/deadline.rbs",
      "sig/phronomy/engine/control_bindings.rbs",
      "sig/phronomy/execution/execution.rbs",
      "sig/phronomy/execution/invocation_controls.rbs",
      "sig/phronomy/execution/async_operation.rbs",
      "sig/phronomy/execution/blocking.rbs",
      "sig/phronomy/engine/execution_receiver.rbs",
      "sig/phronomy/tool.rbs",
      "sig/phronomy/llm_adapter/base.rbs",
      "sig/phronomy/llm_adapter/backends/ruby_llm.rbs",
      "sig/phronomy/agent.rbs",
      "sig/phronomy/workflow.rbs",
      "sig/phronomy/persistence.rbs",
      "sig/phronomy/persistence/errors.rbs",
      "sig/phronomy/agent/store.rbs",
      "sig/phronomy/multi_agent/store.rbs",
      "sig/phronomy/extensions.rbs",
      "sig/phronomy/common.rbs",
      "sig/phronomy/vector_store/base.rbs",
      "sig/phronomy/vector_store/embeddings/base.rbs",
      "sig/phronomy/vector_store/async/async_client.rbs",
      "sig/phronomy/vector_store/embeddings/async/async_client.rbs",
      "sig/phronomy/storage/async/async_client.rbs",
      "sig/phronomy/storage/contracts.rbs",
      "sig/phronomy/storage/backends/in_memory.rbs",
      "sig/phronomy/content_store/contracts.rbs"
    )
  end
end
