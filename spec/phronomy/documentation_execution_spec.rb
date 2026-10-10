# frozen_string_literal: true

require "spec_helper"
require "stringio"
require_relative "../../scripts/check_readme_runnable"

RSpec.describe "Executable application documentation" do
  def check_example(code)
    Tempfile.create(["documentation_spec", ".md"]) do |file|
      file.write("```ruby runnable\n#{code}\n```\n")
      file.flush
      output = StringIO.new
      [RunnableDocumentation.check([file.path], output: output), output.string]
    end
  end

  it "rejects the removed invocation block through the actual Agent API" do
    success, output = check_example(<<~RUBY)
      class ExampleAgent < Phronomy::Agent::Base
        agent_definition id: "documentation-regression", version: 1
        model "gpt-4o-mini"
        instructions "Answer briefly."
      end
      ExampleAgent.new.invoke_async("Hello") { |_| }
    RUBY
    expect(success).to be(false)
    expect(output).to include("ArgumentError")
  end

  it "executes a real Tool and propagates its output into the final answer" do
    success, output = check_example(<<~RUBY)
      class Search < Phronomy::Tool::Base
        description "Search"
        param :query, type: :string, desc: "Query"
        def execute(query:)
          "tool-output: " + query
        end
      end
      class ExampleAgent < Phronomy::Agent::Base
        agent_definition id: "documentation-tool", version: 1
        model "gpt-4o-mini"
        instructions "Search."
        tools(Search => nil)
      end
      result = ExampleAgent.new.invoke("Search")
      raise "Tool was bypassed" unless result.fetch(:output).include?("tool-output:")
    RUBY
    expect(success).to be(true), output
  end

  describe "the documented failure-aware connection" do
    let(:receiver) do
      block = RunnableDocumentation.blocks(File.join(RunnableDocumentation::ROOT, "docs/application-recipes.md"))
        .map(&:last).find { |code| code.start_with?("def request_answer") }
      Object.new.tap { |object| object.singleton_class.class_eval(block.split("class AnswerAgent", 2).first) }
    end
    let(:workflow) { double("workflow") }
    let(:delivery_errors) { [] }

    def forward(task)
      receiver.request_answer(
        agent: double("task producer", invoke_async: task), workflow: workflow,
        workflow_instance_id: "live-stage", question: "Question",
        on_delivery_error: ->(error) { delivery_errors << error }
      )
    end

    it "preserves the minimal example's successful answer payload" do
      expect(workflow).to receive(:signal).with(
        workflow_instance_id: "live-stage", event: :answer_ready, payload: {answer: "Answer"}
      ).and_return(true)
      expect(forward(Phronomy::TaskResult.completed({output: "Answer"}))).to be_nil
      expect(delivery_errors).to be_empty
    end

    [IOError, Phronomy::CancellationError].each do |error_class|
      it "adds explicit #{error_class} delivery to the receiver" do
        error = error_class.new("Operation failed")
        expect(workflow).to receive(:signal).with(
          workflow_instance_id: "live-stage", event: :answer_ready, payload: {error: error}
        ).and_return(true)
        forward(Phronomy::TaskResult.failed(error))
        expect(delivery_errors).to be_empty
      end
    end

    it "reports rejected admission once without changing the source result" do
      task = Phronomy::TaskResult.completed({output: "Answer"})
      expect(workflow).to receive(:signal).once.and_return(false)
      forward(task)
      expect(delivery_errors.map(&:message)).to eq(["Workflow did not accept answer_ready"])
      expect(task.wait_result).to eq(output: "Answer")
    end

    it "reports a signal exception once" do
      error = IOError.new("Delivery failed")
      expect(workflow).to receive(:signal).once.and_raise(error)
      forward(Phronomy::TaskResult.completed({output: "Answer"}))
      expect(delivery_errors).to eq([error])
    end

    it "delivers result conversion errors instead of silently sending nil" do
      expect(workflow).to receive(:signal).with(
        workflow_instance_id: "live-stage", event: :answer_ready,
        payload: {error: an_instance_of(KeyError)}
      ).and_return(true)
      forward(Phronomy::TaskResult.completed({}))
    end
  end
end
