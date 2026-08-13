# frozen_string_literal: true

RSpec.describe Phronomy::Metrics do
  describe ".snapshot" do
    subject(:snap) { described_class.snapshot }

    it "returns a Hash" do
      expect(snap).to be_a(Hash)
    end

    it "includes all expected metric keys" do
      expected_keys = %i[
        offload_pool_active
        offload_pool_queue_length
        offload_pool_abandoned_active
        offload_pool_abandoned_total
        offload_pool_size
        event_loop_queue_depth
        event_loop_queue_max_depth
        event_loop_lag_last_ms
        event_loop_lag_max_ms
        event_loop_lag_average_ms
      ]
      expect(snap.keys).to include(*expected_keys)
    end

    it "reports non-negative numeric values for all metrics" do
      snap.each_value do |value|
        expect(value).to be_a(Numeric)
        expect(value).to be >= 0
      end
    end

    it "reports offload_pool_size equal to the Runtime pool's pool_size" do
      pool = Phronomy::Runtime.instance.offload
      expect(snap[:offload_pool_size]).to eq(pool.pool_size)
    end

    it "reports event_loop_queue_max_depth >= event_loop_queue_depth" do
      expect(snap[:event_loop_queue_max_depth]).to be >= snap[:event_loop_queue_depth]
    end

    it "reports event_loop_lag_max_ms >= event_loop_lag_last_ms" do
      expect(snap[:event_loop_lag_max_ms]).to be >= snap[:event_loop_lag_last_ms]
    end

    it "does not raise when called multiple times" do
      3.times { expect { described_class.snapshot }.not_to raise_error }
    end
  end
end
