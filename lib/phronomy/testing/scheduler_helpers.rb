# frozen_string_literal: true

module Phronomy
  module Testing
    # RSpec helper module that provides a deterministic {Runtime} backed by
    # {Phronomy::Runtime::FakeScheduler}.
    #
    # Include this module in your RSpec describe/context blocks and call
    # {#with_fake_scheduler} to run a block of code inside a fully
    # synchronous, event-logged runtime.
    #
    # @example Basic usage (no clock)
    #   include Phronomy::Testing::SchedulerHelpers
    #
    #   it "records completed events" do
    #     with_fake_scheduler do |sched|
    #       Phronomy::Runtime.instance.spawn(name: "my-task") { 42 }
    #       expect(sched.event_log.map { |e| e[:type] }).to include(:completed)
    #     end
    #   end
    #
    # @example With a FakeClock
    #   include Phronomy::Testing::SchedulerHelpers
    #
    #   it "surfaces pending timers" do
    #     clock = Phronomy::Testing::FakeClock.new
    #     with_fake_scheduler(clock: clock) do |sched|
    #       clock.schedule(seconds: 5) { :fired }
    #       expect(sched.pending_timers.first[:fire_at]).to eq(5.0)
    #     end
    #   end
    module SchedulerHelpers
      # Run +block+ with a {Phronomy::Runtime} that uses
      # {Phronomy::Runtime::FakeScheduler}.
      #
      # The global runtime is replaced for the duration of the block and
      # restored afterwards, whether the block raises or not.
      #
      # @param clock [Phronomy::Testing::FakeClock, nil]
      #   Optional fake clock to inject into the scheduler for timer support
      #   and event timestamping.
      # @yield [scheduler, clock] the {Runtime::FakeScheduler} and the clock
      # @return [Object] the return value of the block
      def with_fake_scheduler(clock: nil)
        scheduler = Phronomy::Runtime::FakeScheduler.new
        scheduler.clock = clock if clock
        runtime = Phronomy::Runtime.new(scheduler: scheduler)
        original = Phronomy::Runtime.instance
        Phronomy::Runtime.instance = runtime
        begin
          yield scheduler, clock
        ensure
          Phronomy::Runtime.instance = original
        end
      end
    end
  end
end
