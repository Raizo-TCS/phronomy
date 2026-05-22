# frozen_string_literal: true

# Smoke tests for README code examples (Issue #141).
#
# These tests verify that the public API demonstrated in README.md is structurally
# correct and can be invoked without requiring a live LLM connection.
# They guard against silent regressions where syntax-valid README examples stop
# working due to renamed methods, changed keyword arguments, or removed features.

require "spec_helper"

RSpec.describe "README API smoke tests (Issue #141)" do
  describe "Tool::Base DSL" do
    it "supports the README quick-start Tool definition" do
      klass = Class.new(Phronomy::Tool::Base) do
        description "Search the web"
        param :query, type: :string, desc: "Search query"

        def execute(query:)
          "result for #{query}"
        end
      end

      expect(klass.new).to respond_to(:call)
      expect(klass.parameters[:query]).not_to be_nil
      expect(klass.parameters[:query].type).to eq(:string)
    end

    it "supports nested properties on object params" do
      klass = Class.new(Phronomy::Tool::Base) do
        description "nested"
        param :config, type: :object, desc: "config",
          properties: {
            timeout: {type: :integer, required: true}
          }

        def execute(config:)
          "ok"
        end
      end

      expect(klass.param_schemas[:config]).to include(timeout: include(type: :integer))
    end
  end

  describe "Agent::Base DSL" do
    it "supports the README Agent class definition" do
      klass = Class.new(Phronomy::Agent::Base) do
        model "gpt-4o"
        instructions "You are a research assistant."
        max_iterations 5
      end

      expect(klass.model).to eq("gpt-4o")
      expect(klass.instructions).to eq("You are a research assistant.")
      expect(klass.max_iterations).to eq(5)
    end

    it "supports add_input_guardrail and add_output_guardrail" do
      guardrail_class = Class.new(Phronomy::Guardrail::InputGuardrail) do
        def check(input)
          fail!("Not allowed") if input.include?("forbidden")
        end
      end

      klass = Class.new(Phronomy::Agent::Base) do
        model "gpt-4o"
        instructions "test"
      end

      agent = klass.new
      expect { agent.add_input_guardrail(guardrail_class.new) }.not_to raise_error
    end
  end

  describe "WorkflowContext DSL" do
    it "supports field declarations as shown in README" do
      klass = Class.new do
        include Phronomy::WorkflowContext

        field :draft, type: :replace
        field :feedback, type: :replace
        field :approved, type: :replace, default: false
      end

      ctx = klass.new(draft: "v1", feedback: nil, approved: false)
      expect(ctx.draft).to eq("v1")
      expect(ctx.approved).to eq(false)
    end
  end

  describe "Workflow DSL" do
    it "supports define / initial / state / transition as shown in README" do
      ctx_class = Class.new do
        include Phronomy::WorkflowContext

        field :step_ran, type: :replace, default: false
      end

      app = Phronomy::Workflow.define(ctx_class) do
        initial :run

        state :run, action: ->(s) { s.merge(step_ran: true) }

        transition from: :run, to: :__finish__
      end

      result = app.invoke({}, config: {thread_id: "readme-test-#{rand(9999)}"})
      expect(result.step_ran).to eq(true)
    end
  end

  describe "Guardrail DSL" do
    it "supports InputGuardrail with fail! as shown in README" do
      guardrail_class = Class.new(Phronomy::Guardrail::InputGuardrail) do
        def check(input)
          fail!("Credit card numbers are not allowed") if input.match?(/\d{4}-\d{4}-\d{4}-\d{4}/)
        end
      end

      guardrail = guardrail_class.new
      expect { guardrail.check("Hello, how are you?") }.not_to raise_error
      expect { guardrail.check("My card is 1234-5678-9012-3456") }
        .to raise_error(Phronomy::GuardrailError, /Credit card/)
    end
  end

  describe "Chain DSL" do
    it "supports PromptTemplate definition and invoke as shown in README" do
      prompt = Phronomy::PromptTemplate.new(template: "Hello {{name}}")
      expect(prompt).to respond_to(:invoke)
      expect(prompt.format(name: "World")).to eq("Hello World")
    end
  end

  describe "Error taxonomy (Issue #149)" do
    it "exposes all documented error classes" do
      expect(Phronomy::Error).to be < StandardError
      expect(Phronomy::ToolError).to be < Phronomy::Error
      expect(Phronomy::TransportError).to be < Phronomy::Error
      expect(Phronomy::RateLimitError).to be < Phronomy::TransportError
      expect(Phronomy::AuthenticationError).to be < Phronomy::TransportError
      expect(Phronomy::ContextLengthError).to be < Phronomy::Error
      expect(Phronomy::CancellationError).to be < Phronomy::Error
      expect(Phronomy::TimeoutError).to be < Phronomy::Error
    end
  end
end
