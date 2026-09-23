# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Storage SPI 2 signatures" do
  it "matches the explicit extension contract and retained Persistence facade" do
    root = File.expand_path("../../..", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, File.join(root, "scripts/storage_spi_snapshot.rb"))
    expect(status.success?).to be(true), output
    expect(output).to eq(File.read(File.join(root, "spec/fixtures/storage_spi_v2_snapshot.json")))
  end
end
