# frozen_string_literal: true

require "spec_helper"

# Regression tests for phronomy.gemspec packaging and runtime dependency correctness.
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

  it "requires RubyLLM 1.15+ for additive Tool-control callbacks" do
    dependency = gemspec.dependencies.find { |item| item.name == "ruby_llm" }
    expect(dependency).not_to be_nil
    expect(dependency.requirement.satisfied_by?(Gem::Version.new("1.14.9"))).to be(false)
    expect(dependency.requirement.satisfied_by?(Gem::Version.new("1.15.0"))).to be(true)
    expect(dependency.requirement.satisfied_by?(Gem::Version.new("2.0.0"))).to be(false)
  end
end
