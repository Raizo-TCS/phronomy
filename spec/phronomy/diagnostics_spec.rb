# frozen_string_literal: true

# Blocking operation diagnostics (Issue #279).
RSpec.describe "Blocking operation diagnostics (Issue #279)" do
  describe "Phronomy::Configuration diagnostic options" do
    it "defaults blocking_io_pool_size to 10" do
      config = Phronomy::Configuration.new
      expect(config.blocking_io_pool_size).to eq(10)
    end

    it "defaults blocking_io_queue_size to 100" do
      config = Phronomy::Configuration.new
      expect(config.blocking_io_queue_size).to eq(100)
    end

    it "accepts blocking_io_pool_size configuration" do
      config = Phronomy::Configuration.new
      config.blocking_io_pool_size = 20
      expect(config.blocking_io_pool_size).to eq(20)
    end
  end

  describe "Phronomy::Diagnostics.snapshot" do
    it "returns a Hash of runtime metrics" do
      snap = Phronomy::Diagnostics.snapshot
      expect(snap).to be_a(Hash)
      expect(snap).to have_key(:blocking_pool_active)
    end
  end

  describe "Phronomy::Diagnostics.dump" do
    it "writes a formatted report to the supplied IO" do
      out = StringIO.new
      Phronomy::Diagnostics.dump(out: out)
      output = out.string
      expect(output).to include("BlockingAdapterPool")
      expect(output).to include("EventLoop")
      expect(output).to include("pool_size")
      expect(output).to include("last_lag_ms")
    end

    it "does not raise when called with no arguments" do
      expect { Phronomy::Diagnostics.dump(out: StringIO.new) }.not_to raise_error
    end
  end

  describe "Phronomy::Diagnostics.assert_not_in_event_loop!" do
    it "does not raise outside the EventLoop" do
      expect { Phronomy::Diagnostics.assert_not_in_event_loop! }.not_to raise_error
    end

    it "raises EventLoopReentrancyError when called from EventLoop thread" do
      el = Phronomy::Runtime.instance.event_loop
      allow(el).to receive(:current?).and_return(true)
      expect {
        Phronomy::Diagnostics.assert_not_in_event_loop!
      }.to raise_error(Phronomy::EventLoopReentrancyError)
    end
  end

  describe "Phronomy::SchedulerReentrancyError" do
    it "is a subclass of Phronomy::Error" do
      expect(Phronomy::SchedulerReentrancyError.ancestors).to include(Phronomy::Error)
    end
  end
end
