# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::CheckpointStore do
  let(:store) { described_class.new }
  let(:checkpoint_id) { "ckpt_123" }
  let(:another_id) { "ckpt_456" }

  describe "#consumed?" do
    context "when checkpoint_id has not been consumed" do
      it "returns false" do
        expect(store.consumed?(checkpoint_id)).to be false
      end
    end

    context "when checkpoint_id has been consumed" do
      before { store.consume!(checkpoint_id) }

      it "returns true" do
        expect(store.consumed?(checkpoint_id)).to be true
      end
    end
  end

  describe "#consume!" do
    context "when checkpoint_id has not been consumed" do
      it "marks the checkpoint as consumed" do
        store.consume!(checkpoint_id)
        expect(store.consumed?(checkpoint_id)).to be true
      end

      it "returns nil" do
        expect(store.consume!(checkpoint_id)).to be_nil
      end
    end

    context "when checkpoint_id has already been consumed" do
      before { store.consume!(checkpoint_id) }

      it "raises CheckpointAlreadyResumedError" do
        expect { store.consume!(checkpoint_id) }
          .to raise_error(Phronomy::CheckpointAlreadyResumedError,
            /checkpoint #{checkpoint_id} has already been resumed/)
      end
    end
  end

  describe "#cleanup!" do
    context "when checkpoint_id has been consumed" do
      before { store.consume!(checkpoint_id) }

      it "removes the checkpoint from tracking" do
        store.cleanup!(checkpoint_id)
        expect(store.consumed?(checkpoint_id)).to be false
      end

      it "allows consume! to be called again for the same checkpoint_id" do
        store.cleanup!(checkpoint_id)
        expect { store.consume!(checkpoint_id) }.not_to raise_error
      end

      it "returns nil" do
        expect(store.cleanup!(checkpoint_id)).to be_nil
      end
    end

    context "when checkpoint_id has not been consumed" do
      it "does not raise an error" do
        expect { store.cleanup!(checkpoint_id) }.not_to raise_error
      end

      it "returns nil" do
        expect(store.cleanup!(checkpoint_id)).to be_nil
      end
    end

    context "when multiple checkpoints exist" do
      before do
        store.consume!(checkpoint_id)
        store.consume!(another_id)
      end

      it "only removes the specified checkpoint" do
        store.cleanup!(checkpoint_id)
        expect(store.consumed?(checkpoint_id)).to be false
        expect(store.consumed?(another_id)).to be true
      end
    end
  end

  describe "#clear!" do
    context "when no checkpoints have been consumed" do
      it "does not raise an error" do
        expect { store.clear! }.not_to raise_error
      end

      it "returns nil" do
        expect(store.clear!).to be_nil
      end
    end

    context "when checkpoints have been consumed" do
      before do
        store.consume!(checkpoint_id)
        store.consume!(another_id)
      end

      it "removes all tracked checkpoints" do
        store.clear!
        expect(store.consumed?(checkpoint_id)).to be false
        expect(store.consumed?(another_id)).to be false
      end

      it "allows consume! to be called again for any checkpoint" do
        store.clear!
        expect { store.consume!(checkpoint_id) }.not_to raise_error
        expect { store.consume!(another_id) }.not_to raise_error
      end

      it "returns nil" do
        expect(store.clear!).to be_nil
      end
    end
  end

  # Test the duck-type contract documentation
  describe "duck-type contract" do
    it "implements consumed?" do
      expect(store).to respond_to(:consumed?)
    end

    it "implements consume!" do
      expect(store).to respond_to(:consume!)
    end

    it "implements cleanup! (optional)" do
      expect(store).to respond_to(:cleanup!)
    end

    it "implements clear! (optional)" do
      expect(store).to respond_to(:clear!)
    end
  end
end
