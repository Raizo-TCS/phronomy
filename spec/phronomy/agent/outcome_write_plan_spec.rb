# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::OutcomeWritePlan::Contents do
  let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
  let(:source) { persistence.contents }
  let(:buffer) { described_class.new(source, write_class: Phronomy::Agent::TerminalPersistenceEvidence::ContentWrite) }

  it "materializes new and historical content together before writing any new bytes" do
    historical = source.put_text("existing")
    expect(source).not_to receive(:put)
    reference = buffer.put_json("message" => "new")
    expect(buffer.fetch_json(reference)).to eq("message" => "new")
    expect(buffer.fetch_text(historical)).to eq("existing")
    expect(buffer.exist?(reference)).to be(true)
    expect(source.exist?(reference)).to be(false)
    expect(buffer.writes.first.bytes).to eq(Phronomy::CanonicalJSON.dump("message" => "new"))
  end

  it "uses the same content identity as the actual store and protects staged bytes from readers" do
    value = "\x00\xFF\x7F".b
    reference = buffer.put(value, canonicalization_version: 1)
    value << "later"
    buffer.fetch(reference) << "reader mutation"
    write = buffer.writes.first
    actual = source.put(write.bytes, canonicalization_version: write.canonicalization_version)
    expect(actual).to eq(reference)
    expect(source.fetch(reference)).to eq("\x00\xFF\x7F".b)
    expect(buffer.fetch(reference)).to eq(source.fetch(reference))
    expect(write.bytes).to be_frozen
  end
end
