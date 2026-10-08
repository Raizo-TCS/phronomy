# frozen_string_literal: true

require "spec_helper"

RSpec.describe "VectorStore external response boundary" do
  let(:invalid_result) { Phronomy::VectorStore::InvalidResultError }

  describe Phronomy::VectorStore::RedisSearch do
    let(:redis) { double("Redis RESP2 client") }
    let(:store) { described_class.new(redis: redis, dimension: 2) }
    let(:fields) { ["score", "0.25", "metadata", '{"label":"A"}'] }

    before do
      allow_any_instance_of(described_class).to receive(:require).with("redis")
      allow(redis).to receive(:call).with("FT.CREATE", any_args)
    end

    def search_response(raw)
      expect(redis).to receive(:call).with("FT.SEARCH", any_args).once.and_return(raw)
      store.search(query_embedding: [1, 0])
    end

    it "keeps a valid empty response distinct from a missing or broken response" do
      expect(search_response([0])).to eq([])
    end

    it "accepts a total larger than the returned page and preserves finite decimal scores" do
      row = search_response([10, "phronomy_doc:a", ["score", "2.5e-1"]]).first
      expect(row).to eq(id: "a", score: 0.75, metadata: {})
    end

    it "omits only the documented null contents of expired/updated documents" do
      result = search_response([2, "phronomy_doc:expired", nil, "phronomy_doc:a", fields])
      expect(result).to eq([{id: "a", score: 0.75, metadata: {label: "A"}}])
    end

    it "allows all returned documents to have expired during the query" do
      expect(search_response([1, "phronomy_doc:expired", nil])).to eq([])
    end

    [nil, [], {}, ["0"], [-1], [1], [0, "phronomy_doc:a", []],
      [1, "phronomy_doc:a"], [1, "phronomy_doc:a", nil, "phronomy_doc:b", nil],
      [1, nil, ["score", "0"]], [1, "foreign:a", ["score", "0"]],
      [1, "phronomy_doc:a", false], [1, "phronomy_doc:a", []],
      [1, "phronomy_doc:a", ["score"]], [1, "phronomy_doc:a", [0, "0"]],
      [1, "phronomy_doc:a", ["score", "0", "score", "1"]]].each do |raw|
      it "rejects malformed search response #{raw.inspect} without partial success" do
        expect { search_response(raw) }.to raise_error(invalid_result)
      end
    end

    [nil, "bad", "0.2junk", "0x1", "NaN", "Infinity", "1e999", Float::NAN,
      Float::INFINITY, Complex(1, 0), [], false].each do |score|
      it "rejects malformed distance #{score.inspect} rather than producing similarity 1" do
        expect { search_response([1, "phronomy_doc:a", ["score", score]]) }
          .to raise_error(invalid_result)
      end
    end

    ["", "{broken", "[]", "null", "1", "false", {}, 1].each do |metadata|
      it "rejects malformed metadata #{metadata.inspect}" do
        expect { search_response([1, "phronomy_doc:a", ["score", "0", "metadata", metadata]]) }
          .to raise_error(invalid_result)
      end
    end

    it "preserves the JSON parser error as cause and does not return preceding valid rows" do
      expect { search_response([2, "phronomy_doc:a", fields, "phronomy_doc:b", ["score", "1", "metadata", "{broken"]]) }
        .to raise_error(invalid_result) { |error| expect(error.cause).to be_a(JSON::ParserError) }
    end

    it "preserves a transport failure without retrying or translating it to a result error" do
      error = IOError.new("connection lost")
      expect(redis).to receive(:call).with("FT.SEARCH", any_args).once.and_raise(error)
      expect { store.search(query_embedding: [1, 0]) }.to raise_error { |actual| expect(actual).to equal(error) }
    end

    context "when reading an initialized index count" do
      before do
        allow(redis).to receive(:call).with("HSET", any_args)
        store.add(id: "a", embedding: [1, 0])
      end

      [0, "0", 12, "12"].each do |count|
        it "accepts documented integer count #{count.inspect}" do
          expect(redis).to receive(:call).with("FT.INFO", any_args).once.and_return(["num_docs", count])
          expect(store.size).to eq(count.to_i)
        end
      end

      [nil, [], {}, ["num_docs"], ["other", 1], ["num_docs", "bad"],
        ["num_docs", nil], ["num_docs", -1], ["num_docs", "-1"],
        ["num_docs", "1.5"], ["num_docs", 1.5], ["num_docs", "1junk"],
        ["num_docs", "0x1"], ["num_docs", "1", "num_docs", "2"]].each do |raw|
        it "rejects malformed count response #{raw.inspect} rather than returning zero" do
          expect(redis).to receive(:call).with("FT.INFO", any_args).once.and_return(raw)
          expect { store.size }.to raise_error(invalid_result)
        end
      end
    end
  end

  describe Phronomy::VectorStore::Pgvector do
    let(:model) { double("VectorDocument") }
    let(:relation) { double("ActiveRecord relation") }
    let(:connection) { double("connection", quote: "'[1.0,0.0]'") }
    let(:store) { described_class.new(model_class: model, dimension: 2) }

    before do
      allow_any_instance_of(described_class).to receive(:require).with("pgvector")
      allow(model).to receive(:connection).and_return(connection)
      allow(model).to receive(:select).and_return(relation)
      allow(relation).to receive(:order).and_return(relation)
    end

    def search_row(id: "a", score: 0.75, metadata: nil)
      row = double("row", id: id, score: score, metadata: metadata)
      expect(relation).to receive(:limit).once.and_return([row])
      store.search(query_embedding: [1, 0])
    end

    it "preserves supported database decoding forms" do
      result = search_row(id: 12, score: "7.5e-1", metadata: {"nested" => {"label" => "A"}})
      expect(result).to eq([{id: "12", score: 0.75, metadata: {nested: {label: "A"}}}])
    end

    [nil, "{}", {}].each do |metadata|
      it "allows empty metadata represented by #{metadata.inspect}" do
        expect(search_row(metadata: metadata).first[:metadata]).to eq({})
      end
    end

    ["", "{broken", "[]", "null", "1", "false", [], 1, {1 => "bad key"}].each do |metadata|
      it "rejects malformed metadata #{metadata.inspect} without inventing an empty object" do
        expect { search_row(metadata: metadata) }.to raise_error(invalid_result)
      end
    end

    it "preserves the JSON parser failure as cause" do
      expect { search_row(metadata: "{broken") }
        .to raise_error(invalid_result) { |error| expect(error.cause).to be_a(JSON::ParserError) }
    end

    [nil, "bad", "0.2junk", "0x1", "NaN", "Infinity", "1e999", Float::NAN,
      Float::INFINITY, Complex(1, 0), [], false].each do |score|
      it "rejects malformed score #{score.inspect} without converting it to zero" do
        expect { search_row(score: score) }.to raise_error(invalid_result)
      end
    end

    [nil, 1.5, false, []].each do |id|
      it "rejects malformed id #{id.inspect} without stringifying it" do
        expect { search_row(id: id) }.to raise_error(invalid_result)
      end
    end

    it "preserves database errors without retrying" do
      error = IOError.new("database unavailable")
      expect(model).to receive(:select).once.and_raise(error)
      expect { store.search(query_embedding: [1, 0]) }.to raise_error { |actual| expect(actual).to equal(error) }
    end
  end
end
