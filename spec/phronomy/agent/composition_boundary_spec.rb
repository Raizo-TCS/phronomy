# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "Agent concrete composition boundary" do
  it "installs the default Policy without initializing Runtime during ordinary loading" do
    source = <<~RUBY
      require "phronomy"
      abort unless Phronomy::Agent::Base.context_policy.equal?(Phronomy::Context::DefaultPolicy.instance)
      abort if Phronomy::Runtime.default_if_initialized_for_test
      puts "lazy composition passed"
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", source)
    expect(status.success?).to be(true), output
  end

  it "preserves inherited Policy changes and explicit child overrides" do
    parent = Class.new(Phronomy::Agent::Base)
    child = Class.new(parent)
    sibling = Class.new(parent)
    explicit = Class.new(Phronomy::Context::ContextPolicy).new
    replacement = Class.new(Phronomy::Context::ContextPolicy).new
    expect(child.context_policy).to equal(Phronomy::Context::DefaultPolicy.instance)
    child.context_policy(explicit)
    parent.context_policy(replacement)
    expect(sibling.context_policy).to equal(replacement)
    expect(child.context_policy).to equal(explicit)
    expect(Phronomy::Agent::Base.context_policy).to equal(Phronomy::Context::DefaultPolicy.instance)
  end

  %i[invoke_async stream_async].each do |entry|
    it "keeps #{entry} Provider work on the Agent owner after default Runtime replacement" do
      original = Phronomy::Runtime.instance
      observed = Queue.new
      callback_owners = Queue.new
      allow(original.offload).to receive(:submit).and_wrap_original do |method, **options, &work|
        method.call(**options) do
          Thread.current[:unit11_test_owner] = original
          begin
            work.call
          ensure
            Thread.current[:unit11_test_owner] = nil
          end
        end
      end
      adapter_class = Class.new(Phronomy::LLMAdapter::Base) do
        define_method(:perform_complete) do |request, cancellation_token:|
          observed << [Thread.current[:unit11_test_owner], request.message, cancellation_token]
          Phronomy::LLMAdapter::Response.new(content: "answer")
        end
        define_method(:perform_stream) do |request, cancellation_token:, &sink|
          observed << [Thread.current[:unit11_test_owner], request.message, cancellation_token]
          sink.call(Phronomy::LLMAdapter::StreamChunk.new(content: "answer"))
          Phronomy::LLMAdapter::Response.new(content: "answer")
        end
        protected :perform_complete, :perform_stream
      end
      stub_const("Unit11Adapter", adapter_class)
      adapter = adapter_class.new
      klass = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "unit11-owner", version: 1
        model "local-test"
      end
      agent = klass.create(on_event: ->(_event) { callback_owners << original.event_loop.current? })
      previous_adapter = Phronomy.configuration.llm_adapter
      # Adapter configuration stays live until dispatch; the execution owner does not.
      Phronomy.configuration.llm_adapter = adapter
      other = Phronomy::Runtime.new
      previous_runtime = Phronomy::Runtime.replace_default_for_test(other)
      token = Phronomy::Concurrency::CancellationToken.new
      result = agent.public_send(entry, "question", config: {cancellation_token: token}).wait_result(timeout: 5)
      expect(result[:output]).to eq("answer")
      owner, message, forwarded_token = observed.pop(timeout: 2)
      expect(owner).to equal(original)
      expect(message).to eq("question")
      expect(forwarded_token).to equal(token)
      expect(callback_owners.size).to be_positive
      expect(Array.new(callback_owners.size) { callback_owners.pop }).to all(be(true))
    ensure
      Phronomy.configuration.llm_adapter = previous_adapter if previous_adapter
      Phronomy::Runtime.restore_default_for_test(previous_runtime) if previous_runtime
      other&.shutdown
    end
  end
end
