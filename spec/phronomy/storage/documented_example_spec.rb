# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "json"

RSpec.describe "Documented Storage async transaction" do
  it "runs the complete public example without a provider or database server" do
    project = File.expand_path("../../..", __dir__)
    guide = File.read(File.join(project, "docs/migrations/storage-async-client.md"))
    code = guide.scan(/```ruby runnable\n(.*?)\n```/m).flatten
    expect(code.size).to eq(1)
    stdout, stderr, status = Open3.capture3(
      {"RUBYOPT" => nil, "RUBYLIB" => nil, "COVERAGE" => nil},
      RbConfig.ruby, "-rbundler/setup", "-I#{project}/lib", "-e", code.first, chdir: project
    )
    expect(status).to be_success, -> { "stdout:\n#{stdout}\nstderr:\n#{stderr}" }
    expect(JSON.parse(stdout)).to eq("text" => "saved")
  end
end
