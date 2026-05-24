# frozen_string_literal: true

# Blocking operation diagnostics (Issue #279).
RSpec.describe "Blocking operation diagnostics (Issue #279)" do
  describe "Phronomy::Configuration diagnostic options" do
    it "defaults scheduler_debug to false" do
      config = Phronomy::Configuration.new
      expect(config.scheduler_debug).to be(false)
    end

    it "defaults blocking_detect_threshold_ms to nil (disabled)" do
      config = Phronomy::Configuration.new
      expect(config.blocking_detect_threshold_ms).to be_nil
    end

    it "accepts scheduler_debug = true" do
      config = Phronomy::Configuration.new
      config.scheduler_debug = true
      expect(config.scheduler_debug).to be(true)
    end

    it "accepts blocking_detect_threshold_ms = 100" do
      config = Phronomy::Configuration.new
      config.blocking_detect_threshold_ms = 100
      expect(config.blocking_detect_threshold_ms).to eq(100)
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

    it "raises SchedulerReentrancyError when called from EventLoop thread" do
      error = nil
      t = Thread.new do
        Thread.current[:phronomy_current_task] = double("task", name: "event-loop")
        begin
          Phronomy::Diagnostics.assert_not_in_event_loop!
        rescue Phronomy::SchedulerReentrancyError => e
          error = e
        ensure
          Thread.current[:phronomy_current_task] = nil
        end
      end
      t.join
      expect(error).to be_a(Phronomy::SchedulerReentrancyError)
      expect(error.message).to include("invoke_async")
    end
  end

  describe "Phronomy::SchedulerReentrancyError" do
    it "is a subclass of Phronomy::Error" do
      expect(Phronomy::SchedulerReentrancyError.ancestors).to include(Phronomy::Error)
    end
  end
end
