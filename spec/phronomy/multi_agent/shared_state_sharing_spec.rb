# frozen_string_literal: true

require "spec_helper"

RSpec.describe "SharedState application sharing" do
  def member_class(id: "sharing-member", version: 1, &operation)
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: id, version: version
      define_method(:invoke) do |input, config: {}|
        operation&.call(self, input)
        {output: "done", messages: []}
      end
    end
  end

  def tool_class(name)
    Class.new(Phronomy::Tool::Base) do
      tool_name name
      description "Application-owned sharing operation"
      execution_mode :cooperative
      define_method(:execute) { "done" }
    end
  end

  def provider_for(store:, tools:, events: [])
    Object.new.tap do |provider|
      provider.define_singleton_method(:open) do |input:, config:, &block|
        events << [:open, input, config]
        begin
          block.call(Phronomy::MultiAgent::SharedState::Binding.new(store: store, tools: tools))
          :provider_return_is_not_the_team_result
        ensure
          events << [:close, store]
        end
      end
    end
  end

  def team_class(provider, member:, id: "application-sharing", version: 1, aggregate: ->(store) { store })
    Class.new(Phronomy::MultiAgent::SharedState).tap do |team|
      team.sharing(provider, id: id, version: version)
      team.member(member)
      team.max_cycles(1)
      team.aggregate(&aggregate) if aggregate
    end
  end

  it "uses one opaque store for member tools, termination and aggregation" do
    store = Object.new
    events = []
    builders = []
    tool = tool_class("inspect_records")
    member = member_class
    provider = provider_for(store: store, events: events,
      tools: ->(member:, cycle:) {
        builders << [member, cycle]
        {tool => nil}
      })
    team = team_class(provider, member: member, aggregate: ->(received) {
      events << [:aggregate, received]
      :summary
    })
    team.max_cycles(5)
    team.terminate_when { |received|
      events << [:terminate, received]
      true
    }
    config = {request_id: "request-17"}

    result = team.new.invoke("Review inventory", config: config)

    expect(result).to eq(output: :summary, cycles: 1, terminated_by: :terminate_when)
    expect(builders).to eq([[member, 1]])
    expect(events).to eq([
      [:open, "Review inventory", config],
      [:terminate, store],
      [:aggregate, store],
      [:close, store]
    ])
  end

  it "builds tools for each original registered member and cycle" do
    first = member_class(id: "first-sharing-member")
    second = member_class(id: "second-sharing-member")
    built = []
    provider = provider_for(store: {}, tools: ->(member:, cycle:) {
      built << [member, cycle]
      {}
    })
    team = team_class(provider, member: first)
    team.member(second)
    team.max_cycles(2)

    team.new.invoke("Review inventory")

    expect(built).to eq([[first, 1], [second, 1], [first, 2], [second, 2]])
  end

  it "preserves member tools and aliases without injecting built-in sharing tools" do
    existing_tool = tool_class("original_tool")
    sharing_tool = tool_class("record_query")
    observed = []
    member = member_class do |agent, _input|
      observed << [agent.class.tools, agent.class.tool_aliases]
    end
    member.tools(existing_tool => "inspect_source")
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {sharing_tool => "find_records"} })

    team_class(provider, member: member).new.invoke("Review inventory")

    expect(observed.first.first).to contain_exactly(existing_tool, sharing_tool)
    expect(observed.first.last).to include(existing_tool => "inspect_source", sharing_tool => "find_records")
    expect(observed.first.first.map(&:tool_name)).not_to include("read_store", "write_finding")
    expect(member.tools).to eq([existing_tool])
    expect(member.tool_aliases).to include(existing_tool => "inspect_source")
  end

  it "keeps the member ContextPolicy and does not embed opaque store contents" do
    store = Object.new
    store.define_singleton_method(:read_all) { raise "SharedState must not read this store" }
    store.define_singleton_method(:size) { raise "SharedState must not inspect this store" }
    store.define_singleton_method(:to_s) { raise "SharedState must not serialize this store" }
    policy = Phronomy::Context::ContextPolicy.new
    received = []
    member = member_class do |agent, input|
      received << [agent.class.context_policy, input]
    end
    member.context_policy(policy)
    provider = provider_for(store: store, tools: ->(member:, cycle:) { {} })
    team = Class.new(Phronomy::MultiAgent::SharedState) do
      sharing provider, id: "opaque-sharing", version: 1
      member member, instruction: "Inspect permissions"
      coordination "Use application record tools"
      max_cycles 1
      aggregate { |_store| :done }
    end

    team.new.invoke("Review account access")

    expect(received.first.first).to equal(policy)
    expect(received.first.last).to include("Use application record tools", "Inspect permissions", "Review account access")
    expect(received.first.last).not_to include("Findings so far", "read_store", "write_finding")
  end

  it "lets the provider isolate stores between invocations of one coordinator" do
    opened = []
    provider = Object.new
    provider.define_singleton_method(:open) do |input:, config:, &block|
      store = {input: input, records: []}
      opened << store
      block.call(Phronomy::MultiAgent::SharedState::Binding.new(store: store,
        tools: ->(member:, cycle:) { {} }))
    end
    team = team_class(provider, member: member_class,
      aggregate: ->(store) {
        store[:records] << store[:input]
        store[:records].dup
      })
    coordinator = team.new

    first = coordinator.invoke("first")
    second = coordinator.invoke("second")

    expect(first[:output]).to eq(["first"])
    expect(second[:output]).to eq(["second"])
    expect(opened.first).not_to equal(opened.last)
  end

  it "runs provider cleanup and preserves the original member failure" do
    failure = RuntimeError.new("member failed")
    events = []
    store = {}
    member = member_class { |_agent, _input| raise failure }
    provider = provider_for(store: store, tools: ->(member:, cycle:) { {} }, events: events)

    expect { team_class(provider, member: member).new.invoke("Review") }
      .to raise_error { |error| expect(error).to equal(failure) }
    expect(events.last).to eq([:close, store])
  end

  it "runs provider cleanup when aggregation fails" do
    failure = RuntimeError.new("aggregation failed")
    events = []
    store = {}
    provider = provider_for(store: store, tools: ->(member:, cycle:) { {} }, events: events)
    team = team_class(provider, member: member_class, aggregate: ->(_store) { raise failure })

    expect { team.new.invoke("Review") }.to raise_error { |error| expect(error).to equal(failure) }
    expect(events.last).to eq([:close, store])
  end

  it "releases a completed member before aggregation and provider cleanup" do
    events = []
    store = {}
    member = member_class { |_agent, _input| events << :invoked }
    member.define_method(:unload!) {
      events << :released
      true
    }
    provider = provider_for(store: store, tools: ->(member:, cycle:) { {} }, events: events)
    team = team_class(provider, member: member, aggregate: ->(_store) {
      events << :aggregated
      :done
    })

    team.new.invoke("Review")

    expect(events).to eq([[:open, "Review", {}], :invoked, :released, :aggregated, [:close, store]])
  end

  it "releases a failed member before provider cleanup without aggregating" do
    events = []
    store = {}
    failure = RuntimeError.new("member failed")
    member = member_class { |_agent, _input|
      events << :invoked
      raise failure
    }
    member.define_method(:unload!) {
      events << :released
      true
    }
    provider = provider_for(store: store, tools: ->(member:, cycle:) { {} }, events: events)
    team = team_class(provider, member: member, aggregate: ->(_store) { events << :aggregated })

    expect { team.new.invoke("Review") }.to raise_error { |error| expect(error).to equal(failure) }
    expect(events).to eq([[:open, "Review", {}], :invoked, :released, [:close, store]])
  end

  it "rejects an overridden invoke that returns a suspended result without releasing or advancing the member" do
    events = []
    suspended_result = {suspended: true, execution_id: "execution-17", approval_request: {id: "approval-3"}}
    member = member_class
    member.define_method(:invoke) { |_input, config: {}| suspended_result }
    member.define_method(:unload!) { events << :released }
    member.define_method(:cancel) { events << :cancelled }
    later = member_class(id: "later-member") { |_agent, _input| events << :later_invoked }
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {} }, events: events)
    team = team_class(provider, member: member, aggregate: ->(_store) { events << :aggregated })
    team.member(later)

    expect { team.new.invoke("Review") }
      .to raise_error(Phronomy::MultiAgent::SharedState::MemberLifecycleError) { |error|
        expect(error.reason).to eq(:suspended)
        expect(error.agent).to be_a(member)
        expect(error.result).to equal(suspended_result)
        expect(error.primary_error).to be_nil
        expect(error.release_error).to be_nil
      }
    expect(events).to eq([[:open, "Review", {}], [:close, {}]])
  end

  it "reports member and release errors together while preserving the primary cause" do
    failure = RuntimeError.new("member failed")
    release_failure = RuntimeError.new("release failed")
    events = []
    member = member_class { |_agent, _input| raise failure }
    member.define_method(:unload!) { raise release_failure }
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {} }, events: events)

    expect { team_class(provider, member: member).new.invoke("Review") }
      .to raise_error(Phronomy::MultiAgent::SharedState::MemberLifecycleError) { |error|
        expect(error.reason).to eq(:release_failed)
        expect(error.agent).to be_a(member)
        expect(error.primary_error).to equal(failure)
        expect(error.release_error).to equal(release_failure)
        expect(error.cause).to equal(failure)
      }
    expect(events.last).to eq([:close, {}])
  end

  it "reports a release failure after a successful member without aggregating" do
    release_failure = RuntimeError.new("release failed")
    events = []
    member = member_class
    member.define_method(:unload!) { raise release_failure }
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {} }, events: events)
    team = team_class(provider, member: member, aggregate: ->(_store) { events << :aggregated })

    expect { team.new.invoke("Review") }
      .to raise_error(Phronomy::MultiAgent::SharedState::MemberLifecycleError) { |error|
        expect(error.reason).to eq(:release_failed)
        expect(error.primary_error).to be_nil
        expect(error.release_error).to equal(release_failure)
        expect(error.cause).to equal(release_failure)
      }
    expect(events).to eq([[:open, "Review", {}], [:close, {}]])
  end

  it "requires custom aggregation before opening application resources" do
    events = []
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {} }, events: events)
    team = team_class(provider, member: member_class, aggregate: nil)

    expect { team.new.invoke("Review") }.to raise_error(ArgumentError, /aggregate/i)
    expect(events).to eq([])
  end

  it "rejects a provider that returns without yielding" do
    provider = Object.new
    provider.define_singleton_method(:open) { |input:, config:| :unused }

    expect { team_class(provider, member: member_class).new.invoke("Review") }
      .to raise_error(ArgumentError)
  end

  it "rejects a second yield before running the members a second time" do
    invocations = 0
    closed = false
    binding = Phronomy::MultiAgent::SharedState::Binding.new(store: {}, tools: ->(member:, cycle:) { {} })
    provider = Object.new
    provider.define_singleton_method(:open) do |input:, config:, &block|
      block.call(binding)
      block.call(binding)
    ensure
      closed = true
    end
    member = member_class { |_agent, _input| invocations += 1 }

    expect { team_class(provider, member: member).new.invoke("Review") }
      .to raise_error(ArgumentError)
    expect(invocations).to eq(1)
    expect(closed).to be(true)
  end

  it "rejects a retained callback after the provider has returned" do
    callback = nil
    invocations = 0
    binding = Phronomy::MultiAgent::SharedState::Binding.new(store: {}, tools: ->(member:, cycle:) { {} })
    provider = Object.new
    provider.define_singleton_method(:open) do |input:, config:, &block|
      callback = block
      block.call(binding)
    end
    member = member_class { |_agent, _input| invocations += 1 }
    team_class(provider, member: member).new.invoke("Review")

    expect { callback.call(binding) }.to raise_error(ArgumentError)
    expect(invocations).to eq(1)
  end

  it "rejects a yielded value that is not a Sharing Binding" do
    provider = Object.new
    provider.define_singleton_method(:open) { |input:, config:, &block| block.call({store: {}}) }

    expect { team_class(provider, member: member_class).new.invoke("Review") }
      .to raise_error(ArgumentError)
  end

  it "rejects a non-callable tools builder" do
    expect { Phronomy::MultiAgent::SharedState::Binding.new(store: {}, tools: {}) }
      .to raise_error(ArgumentError)
  end

  it "rejects a tools builder result that is not a definition Hash" do
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { [] })

    expect { team_class(provider, member: member_class).new.invoke("Review") }
      .to raise_error(ArgumentError)
  end

  it "rejects a tool definition that does not implement the Tool contract" do
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {Object => nil} })

    expect { team_class(provider, member: member_class).new.invoke("Review") }
      .to raise_error(ArgumentError)
  end

  it "rejects an effective sharing tool name that collides with a member alias" do
    member = member_class
    member.tools(tool_class("member_operation") => "lookup")
    provided = tool_class("lookup")
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {provided => nil} })

    expect { team_class(provider, member: member).new.invoke("Review") }
      .to raise_error(ArgumentError)
  end

  it "rejects duplicate effective names among application sharing tools" do
    first = tool_class("first_lookup")
    second = tool_class("second_lookup")
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {first => "lookup", second => "lookup"} })

    expect { team_class(provider, member: member_class).new.invoke("Review") }
      .to raise_error(ArgumentError)
  end

  it "does not silently replace a member tool when the same class is supplied again" do
    repeated = tool_class("lookup")
    member = member_class
    member.tools(repeated => "member_lookup")
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {repeated => "sharing_lookup"} })

    expect { team_class(provider, member: member).new.invoke("Review") }
      .to raise_error(ArgumentError)
    expect(member.tool_aliases.fetch(repeated)).to eq("member_lookup")
  end

  it "uses a stable sharing identity without changing the original Agent definition" do
    definitions = []
    member = member_class(id: "identity-member", version: 3) do |agent, _input|
      definitions << agent.class.agent_definition
    end
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {} })
    team = team_class(provider, member: member, id: "records-v1", version: 4)

    team.new.invoke("first")
    team.new.invoke("second")
    team_class(provider, member: member, id: "records-v1", version: 5).new.invoke("version changed")
    team_class(provider, member: member, id: "records-v2", version: 4).new.invoke("identity changed")

    expect(definitions[0]).to eq(definitions[1])
    expect(definitions[2]).not_to eq(definitions[0])
    expect(definitions[3]).not_to eq(definitions[0])
    expect(definitions[0]).not_to eq(member.agent_definition)
    expect(member.agent_definition).to eq(id: "identity-member", version: 3)
  end

  it "rejects a provider without the required open operation" do
    expect { team_class(Object.new, member: member_class) }.to raise_error(ArgumentError)
  end

  it "rejects an empty sharing identity" do
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {} })

    expect { team_class(provider, member: member_class, id: "") }.to raise_error(ArgumentError)
  end

  it "rejects an invalid sharing version" do
    provider = provider_for(store: {}, tools: ->(member:, cycle:) { {} })

    expect { team_class(provider, member: member_class, version: 0) }.to raise_error(ArgumentError)
  end
end
