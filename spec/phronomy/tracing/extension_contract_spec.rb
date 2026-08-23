# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Tracing extension contract (ACS-05)" do
  let(:root) { File.expand_path("../../..", __dir__) }

  after { Phronomy.reset_configuration! }

  it "documents shared/concurrent use without claiming automatic span coverage" do
    source = File.read(File.join(root, "lib/phronomy/tracing/base.rb"))

    expect(source).not_to include("Chain and Agent")
    expect(source).to include("may therefore be entered concurrently")
    expect(source).to include("must not assume exclusive single-operation use")
    expect(source).to include("does not guarantee a particular OS thread")
    expect(source).to include("does not promise")
    expect(source).to include(
      "Automatic coverage and correlation semantics are"
    )
  end

  it "allows the same configured custom tracer instance to receive overlapping calls" do
    entered = Queue.new
    release = Queue.new

    tracer_class = Class.new(Phronomy::Tracing::Base) do
      define_method(:start_span) do |name, **_attributes|
        entered << Thread.current.object_id
        release.pop
        name
      end

      define_method(:finish_span) do |_span, **_attributes|
        nil
      end
    end

    tracer = tracer_class.new
    Phronomy.configure do |config|
      config.tracer = tracer
      config.trace_pii = true
    end

    runnable = Class.new { include Phronomy::Runnable }.new
    threads = 2.times.map do |index|
      Thread.new do
        runnable.trace("op-#{index}") { ["result-#{index}", nil] }
      end
    end

    entered_threads = Timeout.timeout(2) do
      2.times.map { entered.pop }
    end

    expect(entered_threads.uniq.size).to eq(2)

    2.times { release << true }
    expect(threads.map(&:value)).to contain_exactly("result-0", "result-1")
  ensure
    2.times { release << true } if defined?(release) && release
    threads&.each { |thread| thread.join(1) }
  end

  it "does not change the existing Tracing::Base callable surface" do
    expect(Phronomy::Tracing::Base.instance_method(:trace).parameters).to eq(
      [[:req, :name], [:key, :input], [:keyrest, :meta]]
    )
    expect(Phronomy::Tracing::Base.instance_method(:start_span).parameters).to eq(
      [[:req, :name], [:keyrest, :attributes]]
    )
    expect(Phronomy::Tracing::Base.instance_method(:finish_span).parameters).to eq(
      [
        [:req, :span],
        [:key, :output],
        [:key, :usage],
        [:key, :error]
      ]
    )
  end
end
