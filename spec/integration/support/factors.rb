# frozen_string_literal: true

# Shared helpers that map integration_test_factors.yaml label values to
# concrete Ruby objects / configuration values used across all pairwise
# integration specs.
#
# Usage (from any spec file):
#   require_relative "support/factors"
#
#   agent_klass = IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_single"))
#   memory      = IntegrationFactors.memory("window")
#   budget      = IntegrationFactors.token_budget("generous")
#
# Add methods for new factors as new spec groups are implemented.
# Fixture classes are defined here as named constants so they can be
# shared without re-opening anonymous classes.

module IntegrationFactors
  LM_STUDIO_MODEL = "openai/gpt-oss-20b"

  # ---------------------------------------------------------------------------
  # Fixture Tool classes
  # ---------------------------------------------------------------------------

  class CalculatorTool < Phronomy::Tool::Base
    description "Adds two integers and returns the sum as a string"
    param :a, type: :integer, desc: "First integer"
    param :b, type: :integer, desc: "Second integer"

    def execute(a:, b:)
      (a + b).to_s
    end
  end

  class WeatherTool < Phronomy::Tool::Base
    description "Returns a brief weather description for a city"
    param :city, type: :string, desc: "Name of the city"

    def execute(city:)
      "Sunny and 22°C in #{city}."
    end
  end

  class AlwaysErrorTool < Phronomy::Tool::Base
    description "Always raises a RuntimeError (used to test on_error: :raise)"
    param :input, type: :string, desc: "Any string input"

    def execute(input:)
      raise "Simulated tool error for input: #{input}"
    end
  end

  class ReturnEmptyOnErrorTool < Phronomy::Tool::Base
    description "Always raises but returns empty (used to test on_error: :return_empty)"
    param :input, type: :string, desc: "Any string input"

    on_error :return_empty

    def execute(input:)
      raise "Simulated tool error for input: #{input}"
    end
  end

  # Used for tool_param_enum tests.
  # valid_value  = one of "Tokyo", "London", "Paris"
  # invalid_value = any other string — execute raises, triggering ToolError
  class EnumCitySelectorTool < Phronomy::Tool::Base
    description "Returns a short fact about a supported city: Tokyo, London, or Paris"
    param :city, type: :string,
      desc: "City to look up; must be one of: Tokyo, London, Paris",
      enum: %w[Tokyo London Paris]

    def execute(city:)
      case city
      when "Tokyo" then "Tokyo is the capital and most populous city of Japan."
      when "London" then "London is the capital city of England and the United Kingdom."
      when "Paris" then "Paris is the capital and most populous city of France."
      else raise "Unknown city '#{city}'; must be Tokyo, London, or Paris"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture Guardrail classes
  # ---------------------------------------------------------------------------

  class PassingInputGuardrail < Phronomy::Guardrail::InputGuardrail
    # no-op: always passes
    def check(_input)
    end
  end

  class BlockingInputGuardrail < Phronomy::Guardrail::InputGuardrail
    def check(_input)
      fail!("Blocked: input rejected by BlockingInputGuardrail")
    end
  end

  class PassingOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
    # no-op: always passes
    def check(_output)
    end
  end

  class BlockingOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
    def check(_output)
      fail!("Blocked: output rejected by BlockingOutputGuardrail")
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_class
  #
  # Builds an anonymous agent subclass pre-configured with the given tools.
  #
  # @param label [String] "base" | "react"
  # @param tools [Array, Hash] tool list in splat or hash form (default: [])
  # @return [Class]
  # ---------------------------------------------------------------------------
  def self.agent_class(label, tools: [])
    base_klass = (label == "react") ? Phronomy::Agent::ReactAgent : Phronomy::Agent::Base
    model_name = LM_STUDIO_MODEL
    tool_arg = tools

    Class.new(base_klass) do
      model model_name
      provider :openai  # directs to openai_api_base (LM Studio); sets assume_model_exists: true
      instructions "You are a helpful assistant. Use tools when they are useful."

      case tool_arg
      when Hash then self.tools(tool_arg)
      when Array then self.tools(*tool_arg) unless tool_arg.empty?
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: memory_type
  #
  # @param label [String] "none" | "window" | "summary" | "composite"
  # @param opts  [Hash]   optional overrides
  #   :k              – WindowMemory k (default 10)
  #   :max_tokens     – SummaryMemory max_tokens (default 4000)
  #   :summarizer_model – SummaryMemory summarizer_model (default nil)
  #   :sources        – CompositeMemory sources array (default single WindowMemory)
  # @return [Phronomy::Memory::Base, nil]
  # ---------------------------------------------------------------------------
  def self.memory(label, **opts)
    case label
    when "none"
      nil
    when "window"
      Phronomy::Memory::WindowMemory.new(k: opts.fetch(:k, 10))
    when "summary"
      Phronomy::Memory::SummaryMemory.new(
        max_tokens: opts.fetch(:max_tokens, 4000),
        summarizer_model: opts[:summarizer_model]
      )
    when "composite"
      sources = opts[:sources] || [
        {memory: Phronomy::Memory::WindowMemory.new(k: 5), weight: 1.0}
      ]
      Phronomy::Memory::CompositeMemory.new(sources: sources)
    when "entity"
      Phronomy::Memory::EntityMemory.new(k: opts.fetch(:k, 20))
    else
      raise ArgumentError, "Unknown memory_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_tools
  #
  # @param label [String] "none" | "splat_single" | "splat_multi" |
  #                       "hash_alias" | "hash_no_alias"
  # @return [Array, Hash]  value suitable for passing to .agent_class(tools: ...)
  # ---------------------------------------------------------------------------
  def self.tools(label)
    case label
    when "none" then []
    when "splat_single" then [CalculatorTool]
    when "splat_multi" then [CalculatorTool, WeatherTool]
    when "hash_alias" then {CalculatorTool => "calc"}
    when "hash_no_alias" then {CalculatorTool => nil}
    else raise ArgumentError, "Unknown agent_tools label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: thread_id
  #
  # @param label [String] "nil" | "present" | "different_threads"
  # @return [nil, String, Array<String>]
  # ---------------------------------------------------------------------------
  def self.thread_id(label)
    case label
    when "nil" then nil
    when "present" then "thread-001"
    when "different_threads" then ["thread-001", "thread-002"]
    else raise ArgumentError, "Unknown thread_id label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: memory_token_budget
  #
  # @param label [String] "nil" | "generous" | "tight"
  # @return [Phronomy::Context::TokenBudget, nil]
  # ---------------------------------------------------------------------------
  def self.token_budget(label)
    case label
    when "nil"
      nil
    when "generous"
      # 128k window, 4k output → ~124k for history; effectively unlimited
      Phronomy::Context::TokenBudget.new(context_window: 131_072, max_output_tokens: 4096)
    when "tight"
      # Very small window to force message trimming
      Phronomy::Context::TokenBudget.new(context_window: 256, max_output_tokens: 64)
    else
      raise ArgumentError, "Unknown memory_token_budget label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: agent_guardrails
  #
  # @param label [String] "none" | "input_only" | "output_only" | "both" |
  #                       "blocking_input" | "blocking_output"
  # @return [Array<Phronomy::Guardrail::Base>]
  # ---------------------------------------------------------------------------
  def self.guardrails(label)
    case label
    when "none" then []
    when "input_only" then [PassingInputGuardrail.new]
    when "output_only" then [PassingOutputGuardrail.new]
    when "both" then [PassingInputGuardrail.new, PassingOutputGuardrail.new]
    when "blocking_input" then [BlockingInputGuardrail.new]
    when "blocking_output" then [BlockingOutputGuardrail.new]
    else raise ArgumentError, "Unknown agent_guardrails label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Helper: attach a list of guardrail instances to an agent
  #
  # @param agent [Phronomy::Agent::Base] agent instance
  # @param list  [Array<Phronomy::Guardrail::Base>] guardrails to attach
  # ---------------------------------------------------------------------------
  def self.apply_guardrails(agent, list)
    list.each do |g|
      case g
      when Phronomy::Guardrail::InputGuardrail then agent.add_input_guardrail(g)
      when Phronomy::Guardrail::OutputGuardrail then agent.add_output_guardrail(g)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: prompt_template_type
  #
  # @param label [String] "human_only" | "with_system" | "multi_variable"
  # @return [Phronomy::Chain::PromptTemplate]
  # ---------------------------------------------------------------------------
  def self.prompt_template(label)
    case label
    when "human_only"
      Phronomy::Chain::PromptTemplate.new(template: "Answer this question: {{question}}")
    when "with_system"
      Phronomy::Chain::PromptTemplate.new(
        template: "Answer this question: {{question}}",
        system_template: "You are a {{role}} expert. Keep answers very short."
      )
    when "multi_variable"
      Phronomy::Chain::PromptTemplate.new(
        template: "Translate {{text}} from {{source_lang}} to {{target_lang}}.",
        system_template: "You are a professional translator."
      )
    else
      raise ArgumentError, "Unknown prompt_template_type label: #{label}"
    end
  end

  # ---------------------------------------------------------------------------
  # Factor: streaming_agent_class
  #
  # Builds an agent class pre-configured for streaming tests.
  #
  # @param label [String] "base" | "react"
  # @param tools [Array, Hash] tool list (default [])
  # @param instructions [String, Phronomy::Chain::PromptTemplate] instructions
  # @return [Class]
  # ---------------------------------------------------------------------------
  def self.streaming_agent_class(label, tools: [], instructions: "You are a helpful assistant.")
    base_klass = (label == "react") ? Phronomy::Agent::ReactAgent : Phronomy::Agent::Base
    model_name = LM_STUDIO_MODEL
    tool_arg = tools
    instr = instructions

    Class.new(base_klass) do
      model model_name
      provider :openai
      self.instructions(instr)

      case tool_arg
      when Hash then self.tools(tool_arg)
      when Array then self.tools(*tool_arg) unless tool_arg.empty?
      end
    end
  end
end
