# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tool class configuration inheritance" do
  let(:capability_base) { Phronomy::Agent::Context::Capability::Base }

  def passthrough_filter
    Class.new(Phronomy::Filter::Base) do
      def call(value, **_context)
        value
      end
    end.new
  end

  def configured_tool_class
    Class.new(capability_base) do
      tool_name "configured_tool"
      description "Configured tool"
      execution_mode :cooperative
      on_error :suppress
      on_schema_error :raise
      max_result_size 321
      requires_approval true
      approval_facts { |_args, _context| {source: "configured"} }
      redact_params :secret
      with_params temperature: 0.25

      param :mode,
        type: :string,
        desc: "Mode",
        enum: %w[fast safe]

      param :options,
        type: :object,
        desc: "Options",
        properties: {
          timeout: {
            type: :integer,
            desc: "Timeout",
            required: true
          }
        }

      def execute(mode:, options:)
        "#{mode}:#{options.fetch(:timeout)}"
      end
    end
  end

  describe "Capability::Base subclassing" do
    it "inherits class-level Tool configuration except tool_name" do
      parent = configured_tool_class
      child = Class.new(parent)

      expect(child.tool_name).to be_nil
      expect(child.description).to eq("Configured tool")
      expect(child.desc).to eq("Configured tool")

      expect(child.parameters.keys).to contain_exactly(:mode, :options)
      expect(child.param_enums.fetch(:mode)).to eq(%w[fast safe])
      expect(child.param_schemas.dig(:options, :timeout, :type)).to eq(:integer)

      expect(child.provider_params).to eq(temperature: 0.25)
      expect(child.execution_mode).to eq(:cooperative)
      expect(child.on_error).to eq(:suppress)
      expect(child.on_schema_error).to eq(:raise)
      expect(child.max_result_size).to eq(321)
      expect(child.requires_approval).to be(true)
      expect(child.approval_facts.call({}, nil)).to eq(source: "configured")
      expect(child.redact_params).to include(:secret)

      schema = child.new.params_schema
      expect(schema.dig("properties", "mode", "enum")).to eq(%w[fast safe])
      expect(schema.dig("properties", "options", "properties", "timeout", "type"))
        .to eq("integer")
    end

    it "allows child classes to extend mutable registries without modifying the parent" do
      parent = configured_tool_class
      child = Class.new(parent) do
        param :extra, type: :string, desc: "Extra"
        with_params temperature: 0.5, top_p: 0.8
      end

      expect(child.parameters.keys).to contain_exactly(:mode, :options, :extra)
      expect(parent.parameters.keys).to contain_exactly(:mode, :options)

      expect(child.provider_params).to eq(temperature: 0.5, top_p: 0.8)
      expect(parent.provider_params).to eq(temperature: 0.25)
    end

    it "deep-copies enum and nested-schema registries before child mutation" do
      parent = configured_tool_class
      child = Class.new(parent)

      child.param_enums.fetch(:mode) << "experimental"
      child.param_schemas.dig(:options, :timeout)[:desc] = "Child timeout"

      expect(parent.param_enums.fetch(:mode)).to eq(%w[fast safe])
      expect(parent.param_schemas.dig(:options, :timeout, :desc)).to eq("Timeout")
    end

    it "inherits an explicit RubyLLM .params schema definition" do
      parent = Class.new(capability_base) do
        description "Explicit schema"

        params(
          type: "object",
          properties: {
            query: {
              type: "string"
            }
          },
          required: ["query"],
          additionalProperties: false
        )

        def execute(query:)
          query
        end
      end
      child = Class.new(parent)

      expect(child.params_schema_definition).to equal(parent.params_schema_definition)
      expect(child.new.params_schema).to eq(parent.new.params_schema)
    end

    it "allows scalar policy settings to be overridden without modifying the parent" do
      parent = configured_tool_class
      child = Class.new(parent) do
        tool_name "child_tool"
        description "Child tool"
        execution_mode :offloaded
        on_error :raise
        on_schema_error :return_error
        max_result_size 64
        requires_approval false
      end

      expect(child.tool_name).to eq("child_tool")
      expect(child.description).to eq("Child tool")
      expect(child.execution_mode).to eq(:offloaded)
      expect(child.on_error).to eq(:raise)
      expect(child.on_schema_error).to eq(:return_error)
      expect(child.max_result_size).to eq(64)
      expect(child.requires_approval).to be(false)

      expect(parent.tool_name).to eq("configured_tool")
      expect(parent.description).to eq("Configured tool")
      expect(parent.execution_mode).to eq(:cooperative)
      expect(parent.on_error).to eq(:suppress)
      expect(parent.on_schema_error).to eq(:raise)
      expect(parent.max_result_size).to eq(321)
      expect(parent.requires_approval).to be(true)
    end
  end

  describe "Agent::Base Tool decorators" do
    it "preserves Tool configuration through a result-filter wrapper" do
      tool_class = configured_tool_class
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "tool-config-result-filter", version: 1
        model "test"
        tools tool_class => nil
      end
      agent = agent_class.new
      agent.add_tool_result_filter(passthrough_filter)

      prepared = agent.send(:prepare_tool_class, tool_class)

      expect(prepared.new.name).to eq("configured_tool")
      expect(prepared.description).to eq("Configured tool")
      expect(prepared.parameters.keys).to contain_exactly(:mode, :options)
      expect(prepared.param_enums.fetch(:mode)).to eq(%w[fast safe])
      expect(prepared.param_schemas.dig(:options, :timeout, :type)).to eq(:integer)
      expect(prepared.provider_params).to eq(temperature: 0.25)
      expect(prepared.execution_mode).to eq(:cooperative)
      expect(prepared.on_error).to eq(:suppress)
      expect(prepared.on_schema_error).to eq(:raise)
      expect(prepared.max_result_size).to eq(321)
      expect(prepared.requires_approval).to be(true)

      schema = prepared.new.params_schema
      expect(schema.dig("properties", "mode", "enum")).to eq(%w[fast safe])
      expect(schema.dig("properties", "options", "properties", "timeout", "type"))
        .to eq("integer")
    end

    it "preserves Tool configuration through alias and result-filter wrappers together" do
      tool_class = configured_tool_class
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "tool-config-alias-filter", version: 1
        model "test"
        tools tool_class => "configured_alias"
      end
      agent = agent_class.new
      agent.add_tool_result_filter(passthrough_filter)

      prepared = agent.send(:prepare_tool_class, tool_class)

      expect(prepared.new.name).to eq("configured_alias")
      expect(prepared.description).to eq("Configured tool")
      expect(prepared.parameters.keys).to contain_exactly(:mode, :options)
      expect(prepared.execution_mode).to eq(:cooperative)
      expect(prepared.on_error).to eq(:suppress)
      expect(prepared.max_result_size).to eq(321)
    end
  end

  describe "MultiAgent::Orchestrator Tool decorator" do
    it "preserves generated subagent Tool description and input schema" do
      child_agent = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "tool-config-child-agent", version: 1
        model "test"
      end

      orchestrator_class = Class.new(Phronomy::MultiAgent::Orchestrator) do
        subagent :worker, child_agent
      end
      orchestrator = orchestrator_class.new
      original = orchestrator_class.tools.first

      prepared = orchestrator.send(:prepare_tool_class, original)

      expect(prepared.new.name).to eq("dispatch_to_worker")
      expect(prepared.description).to include("Dispatch work to the worker subagent")
      expect(prepared.parameters.keys).to contain_exactly(:input)

      schema = prepared.new.params_schema
      expect(schema.dig("properties", "input", "type")).to eq("string")
      expect(schema.fetch("required")).to include("input")
    end
  end
end
