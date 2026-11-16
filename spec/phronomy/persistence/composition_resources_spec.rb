# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Public persistence resource catalogs" do
  def agent_root(id)
    Phronomy::Agent::AgentRoot.create(agent_id: id,
      agent_definition_id: "public-catalog", agent_definition_version: 1)
  end

  it "composes all stores over a backend constructed from the public catalog" do
    catalog = Phronomy::PersistenceComposition.resources
    backend = Phronomy::Storage::Backends::InMemory.new(resources: catalog)
    stores = Phronomy::PersistenceComposition.build(backend: backend)
    root = agent_root("all-domains")

    stores.agent.transaction { |records| records.agents.create(root) }
    content_id = stores.agent.contents.put_text("public catalog")

    expect(stores.coordinator.backend).to equal(backend)
    expect(stores.multi_agent.agent_store).to equal(stores.agent)
    expect(stores.agent.agents.load(root.agent_id).to_h).to eq(root.to_h)
    expect(stores.agent.contents.fetch_text(content_id)).to eq("public catalog")
    catalog.each { |resource| expect(backend.resources.fetch(resource.id)).to equal(resource) }
  end

  it "constructs an isolated Agent backend from its public resource subset" do
    catalog = Phronomy::PersistenceComposition.agent_resources
    backend = Phronomy::Storage::Backends::InMemory.new(resources: catalog)
    store = Phronomy::PersistenceComposition.agent(backend: backend)
    root = agent_root("agent-only")

    store.transaction { |records| records.agents.create(root) }
    expect(store.agents.load(root.agent_id).to_h).to eq(root.to_h)
    expect(catalog.map(&:id)).to all(match(/\A(?:agent\.|content\.)/))
    expect { Phronomy::PersistenceComposition.build(backend: backend) }
      .to raise_error(Phronomy::Persistence::UnsupportedBackendError)
  end

  it "keeps catalogs immutable and preserves Resource identity across calls and subsets" do
    full = Phronomy::PersistenceComposition.resources
    agent = Phronomy::PersistenceComposition.agent_resources
    repeated = Phronomy::PersistenceComposition.resources.to_h { |resource| [resource.id, resource] }

    [full, agent].each do |catalog|
      expect(catalog).to be_frozen
      expect(catalog).to all(be_frozen)
      expect(catalog.map(&:id).uniq.size).to eq(catalog.size)
      expect { catalog.clear }.to raise_error(FrozenError)
      catalog.each { |resource| expect(repeated.fetch(resource.id)).to equal(resource) }
    end
  end

  [:resources, :agent_resources].each do |method|
    it "loads #{method} without selecting a backend, opening a database or starting Runtime" do
      source = <<~'CODE'
        require "phronomy"
        Phronomy::Storage::Backend.define_singleton_method(:new) { |*| raise "backend constructed" }
        Phronomy::Runtime.define_singleton_method(:instance) { raise "Runtime requested" }
        before = $LOADED_FEATURES.dup
        catalog = Phronomy::PersistenceComposition.public_send(ARGV.fetch(0))
        abort "empty catalog" if catalog.empty?
        loaded = $LOADED_FEATURES - before
        abort "physical driver loaded" unless loaded.grep(%r{/(?:storage/backends|active_record|sqlite3|pg|redis)(?:/|\.rb)}).empty?
        implementations = %r{/phronomy/(?:agent/store|multi_agent/store|workflow/persistence/state_repository)\.rb\z}
        abort "domain store constructed" unless loaded.grep(implementations).empty?
        if ARGV.fetch(0) == "agent_resources"
          abort "unrelated schemas loaded" unless loaded.grep(%r{/phronomy/(?:multi_agent|workflow)/}).empty?
        end
        abort "Runtime started" if Phronomy::Runtime.default_if_initialized_for_test
        puts "declarations only"
      CODE
      project = File.expand_path("../../..", __dir__)
      output, status = Open3.capture2e(
        {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
        RbConfig.ruby, "-rbundler/setup", "-I#{project}/lib", "-e", source, method.to_s,
        chdir: project
      )
      expect(status.success?).to be(true), output
      expect(output).to include("declarations only")
    end
  end
end
