# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Automatic tracing finish resource isolation" do
  def take(queue)
    Timeout.timeout(3) { queue.pop }
  end

  def configure_tracer
    @started = started = Queue.new
    @release = release = Queue.new
    @finished = finished = Queue.new
    @warnings = warnings = Queue.new
    tracer = Class.new(Phronomy::Tracing::Base) do
      def start_span(name, **) = name

      define_method(:finish_span) do |span, **|
        if span == "slow"
          started << true
          release.pop
        end
        finished << span
        nil
      end
    end.new
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    Phronomy.configure do |configuration|
      configuration.tracer = tracer
      configuration.logger = logger
      configuration.offload_pool_size = 1
      configuration.offload_queue_size = 1
    end
    @runtime = Phronomy::Runtime.instance
  end

  def finish_without_blocking(name)
    handle = Phronomy::Tracing::Automatic.start(name)
    Phronomy::WaitPolicy.without_blocking do
      Phronomy::Tracing::Automatic.finish(handle, output: "observed")
    end
  end

  def start_slow_finish
    finish_without_blocking("slow")
    take(@started)
    @trace_pool = @runtime.pool(:automatic_tracing, size: 1, queue_size: 100)
  end

  after do
    @release << true if @release
    @business_release << true if @business_release
    @runtime&.shutdown(timeout: 1, cancel_grace: 1)
    # A prior bounded shutdown may correctly retain an incomplete result. Join
    # the captured pool after releasing the test gate so no worker outlives it.
    @trace_pool&.shutdown(drain_timeout: 3)
  end

  it "keeps the business queue available while a custom tracing finish is blocked" do
    configure_tracer
    business_started = Queue.new
    @business_release = business_release = Queue.new
    running = Phronomy::Blocking.call_async do
      business_started << true
      business_release.pop
    end
    take(business_started)
    start_slow_finish

    expect(@runtime.offload.queue_depth).to eq(0)
    queued = Phronomy::Blocking.call_async { :business_completed }
    expect(@runtime.offload.queue_depth).to eq(1)
    @business_release << true
    running.wait_result(timeout: 3)

    expect(queued.wait_result(timeout: 3)).to eq(:business_completed)
    expect(@trace_pool.active_count).to eq(1)
    expect(@finished.empty?).to be(true)
    expect(@warnings.empty?).to be(true)
  end

  it "records tracing finish while the business worker and queue are already full" do
    configure_tracer
    business_started = Queue.new
    @business_release = business_release = Queue.new
    running = Phronomy::Blocking.call_async do
      business_started << true
      business_release.pop
      :running_completed
    end
    take(business_started)
    queued = Phronomy::Blocking.call_async { :queued_completed }
    expect(@runtime.offload.queue_depth).to eq(1)

    expect(finish_without_blocking("independent")).to be_nil

    expect(take(@finished)).to eq("independent")
    expect(@runtime.offload.queue_depth).to eq(1)
    expect(running.done?).to be(false)
    expect(queued.done?).to be(false)
    expect(@warnings.empty?).to be(true)
    @business_release << true
    expect(running.wait_result(timeout: 3)).to eq(:running_completed)
    expect(queued.wait_result(timeout: 3)).to eq(:queued_completed)
  end

  it "bounds tracing backlog and preserves business capacity when trace admission is refused" do
    configure_tracer
    start_slow_finish
    expect(@trace_pool.pool_size).to eq(1)
    expect(@trace_pool.queue_size).to eq(100)
    100.times { |index| finish_without_blocking("queued-#{index}") }
    expect(@trace_pool.queue_depth).to eq(100)

    expect(finish_without_blocking("refused")).to be_nil

    expect(take(@warnings)).to match(/automatic tracing finish failed for refused: Phronomy::BackpressureError/)
    expect(@warnings.empty?).to be(true)
    expect(@trace_pool.queue_depth).to eq(100)
    expect(Phronomy::Blocking.call_async { :business_completed }.wait_result(timeout: 3))
      .to eq(:business_completed)
    expect(@finished.empty?).to be(true)
    @release << true
    @trace_pool.shutdown(drain_timeout: 3)
    recorded = []
    recorded << @finished.pop until @finished.empty?
    expect(recorded).to eq(["slow", *100.times.map { |index| "queued-#{index}" }])
  end

  it "reports incomplete Runtime cleanup while a tracing finish is physically running" do
    configure_tracer
    start_slow_finish

    result = @runtime.shutdown(timeout: 0.01, cancel_grace: 0.01)

    expect(result.cleanup_complete?).to be(false)
    expect(@trace_pool.terminated?).to be(false)
    expect(@trace_pool.active_count).to eq(1)
    expect(@finished.empty?).to be(true)
    @release << true
    @trace_pool.shutdown(drain_timeout: 3)
    expect(@trace_pool.terminated?).to be(true)
    expect(take(@finished)).to eq("slow")
  end

  it "drains accepted tracing finishes before reporting successful Runtime cleanup" do
    configure_tracer
    start_slow_finish
    finish_without_blocking("queued")
    @release << true

    result = @runtime.shutdown(timeout: 1, cancel_grace: 1)

    expect(result.cleanup_complete?).to be(true)
    expect(@trace_pool.terminated?).to be(true)
    expect([take(@finished), take(@finished)]).to eq(["slow", "queued"])
    expect(@warnings.empty?).to be(true)
  end

  it "reports closed Runtime admission without running tracing finish on the control thread" do
    configure_tracer
    expect(@runtime.shutdown(timeout: 1, cancel_grace: 1).cleanup_complete?).to be(true)

    expect(finish_without_blocking("after-shutdown")).to be_nil

    expect(take(@warnings)).to match(/automatic tracing finish failed for after-shutdown: Phronomy::RuntimeShutdownError/)
    expect(@finished.empty?).to be(true)
    expect(Phronomy::Runtime.instance).to equal(@runtime)
    expect(@runtime.__offload_if_initialized).to be_nil
  end
end
