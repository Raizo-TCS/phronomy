# frozen_string_literal: true

RSpec.shared_examples "a persistence content store" do
  let(:content_store) { persistence.contents }

  it "returns the same content_id for the same bytes" do
    first = content_store.put("same".b, canonicalization_version: 1)
    second = content_store.put("same".b, canonicalization_version: 1)

    expect(second).to eq(first)
  end

  it "round-trips binary bytes" do
    bytes = "\x00\xFFpayload".b
    content_id = content_store.put(bytes, canonicalization_version: 1)

    expect(content_store.fetch(content_id)).to eq(bytes)
    expect(content_store.exist?(content_id)).to be(true)
  end

  it "raises NotFoundError for a missing content_id" do
    expect do
      content_store.fetch("sha256:#{"0" * 64}")
    end.to raise_error(Phronomy::Persistence::NotFoundError)
  end

  it "isolates durable bytes from mutation of fetched values" do
    content_id = content_store.put("immutable".b, canonicalization_version: 1)
    fetched = content_store.fetch(content_id)
    fetched << "-caller-change"

    expect(content_store.fetch(content_id)).to eq("immutable".b)
  end

  it "supports UTF-8 text helpers" do
    content_id = content_store.put_text("Grüße")

    expect(content_store.fetch_text(content_id)).to eq("Grüße")
  end

  it "supports canonical JSON helpers" do
    value = {
      "z" => [1, true, nil],
      "a" => {"message" => "hello"}
    }
    content_id = content_store.put_json(value)

    expect(content_store.fetch_json(content_id)).to eq(value)
  end
end
