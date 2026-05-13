# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::StateStore::Encryptor::Base do
  subject(:encryptor) { described_class.new }

  describe "#encrypt" do
    it "raises NotImplementedError" do
      expect { encryptor.encrypt("data") }.to raise_error(NotImplementedError)
    end
  end

  describe "#decrypt" do
    it "raises NotImplementedError" do
      expect { encryptor.decrypt("data") }.to raise_error(NotImplementedError)
    end
  end
end

RSpec.describe Phronomy::StateStore::ActiveRecord do
  # Minimal stub encryptor for testing the save/load encrypt/decrypt path.
  let(:reversing_encryptor) do
    Class.new(Phronomy::StateStore::Encryptor::Base) do
      def encrypt(plaintext) = plaintext.reverse
      def decrypt(ciphertext) = ciphertext.reverse
    end.new
  end

  let(:records) { {} }
  let(:model_class) do
    Class.new do
      attr_accessor :thread_id, :state_json

      def save!
        self.class._store[thread_id] = self
      end

      def self._store
        @_store ||= {}
      end

      def self.upsert(attrs, unique_by:, update_only: nil)
        existing = _store[attrs[:thread_id]]
        if existing
          existing.state_json = attrs[:state_json]
        else
          record = new
          record.thread_id = attrs[:thread_id]
          record.state_json = attrs[:state_json]
          _store[attrs[:thread_id]] = record
        end
      end

      def self.find_or_initialize_by(thread_id:)
        _store[thread_id] || new.tap { |r| r.thread_id = thread_id }
      end

      def self.find_by(thread_id:)
        _store[thread_id]
      end

      def self.where(thread_id:)
        Struct.new(:thread_id).new(thread_id).tap do |q|
          def q.delete_all
            # no-op for this stub
          end
        end
      end
    end
  end

  let(:state_class) do
    Class.new do
      include Phronomy::Graph::Context

      field :value, type: :replace, default: -> {}
    end
  end

  before do
    stub_const("PhronomyStubState", state_class)
  end

  describe "with encryptor:" do
    subject(:store) { described_class.new(model_class: model_class, encryptor: reversing_encryptor) }

    it "stores the encrypted payload (not raw JSON)" do
      state = state_class.new(value: "secret")
      state.set_graph_metadata(thread_id: "t1")
      store.save(state)
      raw = model_class.find_by(thread_id: "t1").state_json
      expect(raw).not_to include('"secret"')
      expect(raw).to include("terces".reverse.reverse)  # sanity: double-reversed == original
    end

    it "round-trips save and load through the encryptor" do
      state = state_class.new(value: "round_trip")
      state.set_graph_metadata(thread_id: "t2")
      store.save(state)
      loaded = store.load("t2")
      expect(loaded.value).to eq("round_trip")
    end

    it "preserves thread_id and graph metadata through the encryptor" do
      state = state_class.new(value: "x")
      state.set_graph_metadata(thread_id: "t3", phase: :awaiting_node_a)
      store.save(state)
      loaded = store.load("t3")
      expect(loaded.thread_id).to eq("t3")
      expect(loaded.halted?).to be true
      expect(loaded.phase).to eq(:awaiting_node_a)
    end
  end

  describe "without encryptor (backward compatible)" do
    subject(:store) { described_class.new(model_class: model_class) }

    it "stores raw JSON without encryption" do
      state = state_class.new(value: "plain")
      state.set_graph_metadata(thread_id: "t4")
      store.save(state)
      raw = model_class.find_by(thread_id: "t4").state_json
      expect(raw).to include('"plain"')
    end

    it "round-trips save and load" do
      state = state_class.new(value: "hello")
      state.set_graph_metadata(thread_id: "t5")
      store.save(state)
      loaded = store.load("t5")
      expect(loaded.value).to eq("hello")
    end

    it "upserts: overwriting the same thread_id updates rather than duplicates (S03)" do
      state1 = state_class.new(value: "first")
      state1.set_graph_metadata(thread_id: "t_upsert")
      store.save(state1)

      state2 = state_class.new(value: "second")
      state2.set_graph_metadata(thread_id: "t_upsert")
      store.save(state2)

      loaded = store.load("t_upsert")
      expect(loaded.value).to eq("second")
    end
  end
end
