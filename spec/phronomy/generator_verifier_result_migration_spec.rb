# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe "Explicit GeneratorVerifier Result migration" do
  it "adds failure only in the migration tool and preserves the input file" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "old.json")
      target = File.join(dir, "new.json")
      old = {output: "answer", confidence: 0.8, citations: [], iterations: 1, review_notes: [],
             confidence_threshold: 0.7, review_approved: true, termination_reason: "accepted", interrupted_phase: nil}
      bytes = JSON.generate(old)
      File.write(source, bytes)
      expect { Phronomy::GeneratorVerifier::Result.from_h(old) }.to raise_error(ArgumentError, /missing/)
      _out, err, status = Open3.capture3(RbConfig.ruby, "scripts/migrate_generator_verifier_result.rb", source, target)
      expect(status.success?).to be(true), err
      result = Phronomy::GeneratorVerifier::Result.from_h(JSON.parse(File.read(target)))
      expect(result).to be_accepted
      expect(result.failure).to be_nil
      expect(File.read(source)).to eq(bytes)
      _out, _err, status = Open3.capture3(RbConfig.ruby, "scripts/migrate_generator_verifier_result.rb", source, target)
      expect(status.success?).to be(false)
    end
  end
end
