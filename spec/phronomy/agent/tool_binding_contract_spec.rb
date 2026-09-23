# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent Tool binding contract" do
  def tool_class(source: nil, calls: [])
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "binding_tool"
      description "Binding contract"
      define_method(:call) do |args, **kwargs|
        calls << [args, kwargs]
        "raw"
      end
      if source
        define_method(:call_async) do |args, **kwargs|
          calls << [args, kwargs]
          source
        end
      end
    end
  end

  def agent_for(tool, alias_name: nil)
    Class.new(Phronomy::Agent::Base) do
      tools tool => alias_name
    end.allocate
  end

  def filter(&block)
    Object.new.tap { |object| object.define_singleton_method(:call, &block) }
  end

  def bind(agent, tool)
    agent.send(:prepare_tool_class, tool, invocation: Object.new)
  end

  it "returns instances unchanged without looking up aliases or filters" do
    tool = tool_class.new
    agent = agent_for(tool)
    expect(agent.class).not_to receive(:tool_aliases)
    expect(agent).not_to receive(:_tool_result_filters_for)
    expect(bind(agent, tool)).to equal(tool)
  end

  it "returns the original class when neither alias nor filters are configured" do
    tool = tool_class
    expect(bind(agent_for(tool), tool)).to equal(tool)
  end

  it "creates the alias before resolving filters and avoids instantiation without filters" do
    events = []
    tool = tool_class
    tool.define_singleton_method(:inherited) { |_child| events << :subclass }
    tool.define_method(:initialize) { raise "unexpected instance" }
    agent = agent_for(tool, alias_name: "bound")
    agent.define_singleton_method(:_tool_result_filters_for) do |original|
      events << [:filters, original]
      []
    end
    prepared = bind(agent, tool)
    expect(prepared.superclass).to equal(tool)
    expect(prepared.tool_name).to eq("bound")
    expect(events).to eq([:subclass, [:filters, tool]])
  end

  it "applies class, instance and original-class scoped filters in order with the effective name" do
    tool = tool_class
    agent = agent_for(tool, alias_name: "bound")
    calls = []
    %i[class instance scoped].each do |stage|
      f = filter do |value, tool_name:, args:|
        calls << [stage, value, tool_name, args]
        "#{value}:#{stage}"
      end
      case stage
      when :class then agent.class.tool_result_filter(f)
      when :instance then agent.add_tool_result_filter(f)
      when :scoped then agent.add_tool_result_filter(tool, f)
      end
    end
    args = {value: "input"}
    expect(bind(agent, tool).new.call(args)).to eq("raw:class:instance:scoped")
    expect(calls.map(&:first)).to eq(%i[class instance scoped])
    expect(calls.map { |entry| entry[2] }).to eq(["bound"] * 3)
    expect(calls.all? { |entry| entry.last.equal?(args) }).to be(true)
    expect(tool.tool_name).to eq("binding_tool")
  end

  it "captures the selected filter list at preparation, without caching prepared classes" do
    tool = tool_class
    agent = agent_for(tool)
    agent.add_tool_result_filter(filter { |value, **| "#{value}:first" })
    first = bind(agent, tool)
    agent.add_tool_result_filter(filter { |value, **| "#{value}:second" })
    second = bind(agent, tool)
    expect(first).not_to equal(second)
    expect(first.new.call({})).to eq("raw:first")
    expect(second.new.call({})).to eq("raw:first:second")
  end

  it "forwards keyword objects and preserves synchronous filter exception identity" do
    calls = []
    tool = tool_class(calls: calls)
    agent = agent_for(tool)
    error = RuntimeError.new("filter failed")
    agent.add_tool_result_filter(filter { |_value, **| raise error })
    args = {}
    config = {}
    token = Object.new
    expect { bind(agent, tool).new.call(args, config: config, cancellation_token: token) }
      .to raise_error { |actual| expect(actual).to equal(error) }
    expect(calls.first.first).to equal(args)
    expect(calls.first.last[:config]).to equal(config)
    expect(calls.first.last[:cancellation_token]).to equal(token)
  end

  it "keeps the default async method so its call path applies filters only once" do
    tool = tool_class
    agent = agent_for(tool)
    count = 0
    agent.add_tool_result_filter(filter { |value, **|
      count += 1
      "#{value}:filtered"
    })
    prepared = bind(agent, tool)
    expect(prepared.instance_method(:call_async).owner).to equal(Phronomy::Agent::Context::Capability::Base)
    allow(Phronomy::Agent::Context::Capability::ToolExecutor).to receive(:call_async) do |tool:, args:, **|
      Phronomy::TaskResult.completed(tool.call(args))
    end
    expect(prepared.new.call_async({}).wait_result).to eq("raw:filtered")
    expect(count).to eq(1)
  end

  [false, true].each do |physical|
    %i[completed failed cancelled filter_failed].each do |outcome|
      it "preserves #{outcome} and #{physical ? "separate" : "implicit"} physical completion" do
        source_type = physical ? Phronomy::Concurrency::PhysicalCompletionTask : Phronomy::TaskResult
        source = source_type.deferred
        calls = []
        tool = tool_class(source: source, calls: calls)
        agent = agent_for(tool, alias_name: "bound")
        error = RuntimeError.new("original failure")
        seen = []
        agent.add_tool_result_filter(filter do |value, tool_name:, args:|
          seen << [value, tool_name, args]
          raise error if outcome == :filter_failed
          "#{value}:filtered"
        end)
        args = {}
        config = {}
        token = Object.new
        filtered = bind(agent, tool).new.call_async(args, config: config, cancellation_token: token)
        expect(filtered.name).to eq("tool-filter-bound")
        expect(filtered.done?).to be(false)
        expect(filtered.physical_complete?).to be(false)
        observation = []
        filtered.on_complete { |value, failure| observation << [value, failure, filtered.physical_complete?] }

        case outcome
        when :completed, :filter_failed then source.complete("value")
        when :failed then source.fail(error)
        when :cancelled then source.cancel!(error)
        end

        expected_status = (outcome == :filter_failed) ? :failed : outcome
        expect(filtered.status).to eq(expected_status)
        expect(observation.length).to eq(1)
        expect(observation.first[2]).to eq(!physical)
        if outcome == :completed
          expect(filtered.wait_result).to eq("value:filtered")
        else
          expect { filtered.wait_result }.to raise_error { |actual| expect(actual).to equal(error) }
        end
        expect(seen.length).to eq(%i[completed filter_failed].include?(outcome) ? 1 : 0)
        expect(seen.first).to eq(["value", "bound", args]) unless seen.empty?
        expect(calls.first.first).to equal(args)
        expect(calls.first.last[:config]).to equal(config)
        expect(calls.first.last[:cancellation_token]).to equal(token)
        if physical
          expect(filtered.physical_complete?).to be(false)
          source.mark_physical_complete!
        end
        expect(filtered.physical_complete?).to be(true)
      end
    end
  end

  [false, true].each do |completed_before_binding|
    it "supports physical completion before logical completion (already done: #{completed_before_binding})" do
      source = Phronomy::Concurrency::PhysicalCompletionTask.deferred
      source.mark_physical_complete!
      source.complete("ready") if completed_before_binding
      tool = tool_class(source: source)
      agent = agent_for(tool)
      agent.add_tool_result_filter(filter { |value, **| "#{value}:filtered" })
      filtered = bind(agent, tool).new.call_async({})
      expect(filtered.physical_complete?).to be(true)
      expect(filtered.done?).to eq(completed_before_binding)
      source.complete("ready") unless completed_before_binding
      expect(filtered.wait_result).to eq("ready:filtered")
    end
  end

  it "recognizes an inherited custom async implementation" do
    source = Phronomy::TaskResult.completed("custom")
    tool = Class.new(tool_class(source: source)) { tool_name "child" }
    agent = agent_for(tool)
    agent.add_tool_result_filter(filter { |value, **| "#{value}:filtered" })
    expect(bind(agent, tool).new.call_async({}).wait_result).to eq("custom:filtered")
  end

  it "does not propagate cancellation of the filtered result back to the source" do
    source = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    tool = tool_class(source: source)
    agent = agent_for(tool)
    seen = []
    agent.add_tool_result_filter(filter { |value, **|
      seen << value
      value
    })
    filtered = bind(agent, tool).new.call_async({})
    filtered.cancel!
    expect(source.status).to eq(:pending)
    source.complete("late")
    expect(seen).to eq(["late"])
    expect(filtered.status).to eq(:cancelled)
    expect(filtered.physical_complete?).to be(false)
    source.mark_physical_complete!
    expect(filtered.physical_complete?).to be(true)
  end

  it "propagates an exception raised before a custom async operation is returned" do
    error = RuntimeError.new("start failed")
    tool = tool_class
    tool.define_method(:call_async) { |_args, **| raise error }
    agent = agent_for(tool)
    agent.add_tool_result_filter(filter { |value, **| value })
    expect { bind(agent, tool).new.call_async({}) }
      .to raise_error { |actual| expect(actual).to equal(error) }
  end
end
