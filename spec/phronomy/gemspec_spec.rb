# frozen_string_literal: true

require "spec_helper"

# Regression tests for phronomy.gemspec packaging correctness.
#
# Finding 2 — vendor/ directory packaged inside the gem (Issue #<tbd>):
#   The gemspec did not exclude vendor/ from spec.files, so bundled dependencies
#   in vendor/bundle were included in the published gem, inflating its size by ~14 MB
#   and shipping third-party code that users do not need.
RSpec.describe "phronomy.gemspec packaging" do
  let(:gemspec) { Gem::Specification.load(File.expand_path("../../phronomy.gemspec", __dir__)) }

  it "does not package any files under vendor/" do
    vendor_files = gemspec.files.select { |f| f.start_with?("vendor/") }
    expect(vendor_files).to be_empty,
      "gemspec includes #{vendor_files.size} vendor/ files; add 'vendor/' to the reject list in spec.files"
  end

  it "does not package spec/ files" do
    spec_files = gemspec.files.select { |f| f.start_with?("spec/") }
    expect(spec_files).to be_empty,
      "gemspec includes spec/ files: #{spec_files.first(5).inspect}"
  end

  it "includes the lib/ directory" do
    lib_files = gemspec.files.select { |f| f.start_with?("lib/") }
    expect(lib_files).not_to be_empty
  end
end
