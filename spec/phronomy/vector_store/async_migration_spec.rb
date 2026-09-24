# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "json"

RSpec.describe "Vector asynchronous API migration" do
  it "runs the documented offline example using the public clients" do
    root = File.expand_path("../../..", __dir__)
    guide = File.read(File.join(root, "docs/migrations/vector-async-clients.md"))
    examples = guide.scan(/^```ruby runnable\n(.*?)^```/m).flatten
    expect(examples.size).to eq(1)
    stdout, stderr, status = Open3.capture3(
      {"COVERAGE" => nil}, RbConfig.ruby, "-rbundler/setup", "-I#{root}/lib",
      "-e", examples.first, chdir: root
    )
    expect(status).to be_success, -> { stderr }
    result = JSON.parse(stdout)
    expect(result.size).to eq(1)
    expect(result.first.fetch("id")).to eq("ruby")
    expect(result.first.fetch("metadata")).to eq("title" => "Ruby guide")
  end

  it "preserves async argument ordering and defaults on the new receivers" do
    expect(Phronomy::VectorStore::AsyncClient.instance_method(:search_async).parameters)
      .to eq([[:keyreq, :query_embedding], [:key, :k], [:key, :cancellation_token], [:key, :timeout]])
    expect(Phronomy::VectorStore::Embeddings::AsyncClient.instance_method(:embed_async).parameters)
      .to eq([[:req, :text], [:opt, :cancellation_token], [:key, :timeout]])
  end
end
