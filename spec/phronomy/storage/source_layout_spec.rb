# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Storage and ContentStore source ownership" do
  def isolated(source)
    project = File.expand_path("../../..", __dir__)
    stdout, stderr, status = Open3.capture3(
      {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
      RbConfig.ruby, "-rbundler/setup", "-I#{project}/lib", "-e", source, chdir: project
    )
    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
  end

  it "loads contracts and implementations without loading a client or additional Engine code" do
    isolated(<<~RUBY)
      require "phronomy"
      before = $LOADED_FEATURES.dup
      Phronomy::Storage::Backend
      Phronomy::ContentStore::Base
      Phronomy::ContentStore::StorageSchema
      loaded = $LOADED_FEATURES - before
      abort "contracts loaded implementations" unless loaded.grep(%r{/(storage|content_store)/backends/}).empty?
      backend = Phronomy::Storage::Backends::InMemory.new
      implementation = Phronomy::ContentStore::StoredContents
      implementation.new(backend.view)
      abort "StoredContents contract changed" unless implementation.superclass == Phronomy::ContentStore::Base
      loaded = $LOADED_FEATURES - before
      abort "backend loaded Engine/client" unless loaded.grep(%r{/phronomy/(engine/|storage/async/)}).empty?
      abort "Storage backend namespace changed" unless backend.class.name == "Phronomy::Storage::Backends::InMemory"
      abort "ContentStore backend namespace leaked" if Phronomy::ContentStore.const_defined?(:Backends, false)
    RUBY
  end

  ["Phronomy::Storage::AsyncClient", "Phronomy::ContentStore::StoredContents"].each do |first|
    it "keeps public identities and starts no Runtime when #{first} loads first" do
      isolated(<<~RUBY)
        require "phronomy"
        #{first}
        client = Phronomy::Storage::AsyncClient
        implementation = Phronomy::ContentStore::StoredContents
        client.new(backend: Phronomy::Storage::Backends::InMemory.new)
        2.times { Zeitwerk::Loader.eager_load_all }
        abort "client identity changed" unless Phronomy::Storage::AsyncClient.equal?(client)
        abort "implementation identity changed" unless Phronomy::ContentStore::StoredContents.equal?(implementation)
        abort "Runtime started" if Phronomy::Runtime.default_if_initialized_for_test
        abort "new Async namespace" if Phronomy::Storage.const_defined?(:Async, false)
      RUBY
    end
  end
end
