# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Tool result transformation and internal async delegation" do
  let(:tool_class) do
    Class.new(Phronomy::Tool::Base) do
      tool_name "transform-delegation"
      param :value, type: :string
      attr_reader :executed_on

      def execute(value:)
        @executed_on = self
        value
      end
    end
  end
  let(:seen) { [] }
  let(:transform) do
    ->(value, name, args) {
      seen << [value, name, args]
      "[#{value}]"
    }
  end

  def decorate(klass = tool_class, &block)
    Phronomy::Tool::Operation.with_result_transform(klass, &block || transform)
  end

  def install_super(klass = tool_class)
    klass.class_eval do
      def call_async(args, cancellation_token: nil, config: {})
        super
      end
    end
  end

  %i[cooperative offloaded].each do |mode|
    context "with #{mode} work" do
      before do
        tool_class.execution_mode mode
        if mode == :offloaded
          @pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 2, queue_size: 4)
          allow(Phronomy::Execution).to receive(:submit) { |**kwargs, &work| @pool.submit(**kwargs, &work) }
        end
      end

      after { @pool&.shutdown(drain_timeout: 1) }

      [false, true].each do |custom|
        it "preserves one configured stage through #{custom ? "custom super" : "default async"}" do
          install_super if custom
          instance = decorate.new
          args = {value: "x"}
          result = Phronomy::Tool::Operation.call_async(tool: instance, args: args)
          expect(result.wait_result(timeout: 3)).to eq("[x]")
          expect(seen).to eq([["x", "transform-delegation", args]])
          expect(seen.first.last).to be(args)
          expect(instance.executed_on).to be(instance)
        end
      end

      it "transforms the final custom result after super, not an intermediate result" do
        tool_class.class_eval do
          def call_async(args, cancellation_token: nil, config: {})
            Phronomy::AsyncOperation.map(super, name: "application-map") { |value| "custom:#{value}" }
          end
        end
        expect(decorate.new.call_async({value: "x"}).wait_result(timeout: 3)).to eq("[custom:x]")
        expect(seen.map(&:first)).to eq(["custom:x"])
      end

      it "preserves repeated decorator registrations of the same transformation" do
        install_super
        instance = decorate(decorate).new
        expect(instance.call_async({value: "x"}).wait_result(timeout: 3)).to eq("[[x]]")
        expect(seen.map(&:first)).to eq(["x", "[x]"])
      end

      it "retains the configured order of different decorator stages" do
        install_super
        first = decorate { |value, *| "first(#{value})" }
        second = decorate(first) { |value, *| "second(#{value})" }
        expect(second.new.call_async({value: "x"}).wait_result(timeout: 3)).to eq("second(first(x))")
      end

      it "supports an inherited custom async method and repeated calls on one instance" do
        install_super
        child = Class.new(tool_class) { tool_name "inherited" }
        instance = decorate(child).new
        2.times do
          expect(instance.call_async({value: "x"}).wait_result(timeout: 3)).to eq("[x]")
        end
        expect(instance.call({value: "x"})).to eq("[x]")
        expect(seen.map(&:first)).to eq(["x"] * 3)
        expect(seen.map { |entry| entry[1] }).to eq(["inherited"] * 3)
      end

      it "retains synchronous filters below a later application async override" do
        inner = decorate
        application = Class.new(inner) do
          tool_name "application-layer"
          def call_async(args, cancellation_token: nil, config: {})
            Phronomy::AsyncOperation.map(super, name: "application-map") { |value| "custom:#{value}" }
          end
        end
        outer = decorate(application)
        expect(outer.new.call_async({value: "x"}).wait_result(timeout: 3)).to eq("[custom:[x]]")
        expect(seen.map(&:first)).to eq(["x", "custom:[x]"])
      end
    end
  end

  it "preserves an explicit application call and the outer async transformation" do
    tool_class.class_eval do
      def call_async(args, **kwargs)
        Phronomy::TaskResult.completed("custom:#{call(args)}")
      end
    end
    expect(decorate.new.call_async({value: "x"}).wait_result).to eq("[custom:[x]]")
    expect(seen.map(&:first)).to eq(["x", "custom:[x]"])
  end

  it "does not bypass application or singleton call overrides" do
    tool_class.execution_mode :cooperative
    install_super
    instance = decorate.new
    instance.define_singleton_method(:call) { |args, **| "application:#{args[:value]}" }
    expect(instance.call_async({value: "x"}).wait_result).to eq("[application:x]")
  end

  it "keeps a pending offloaded invocation independent from a synchronous call on the same instance" do
    install_super
    instance = decorate.new
    pending = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    work = nil
    allow(Phronomy::Execution).to receive(:submit) { |**kwargs, &block|
      work = block
      pending
    }
    async = instance.call_async({value: "async"})
    expect(instance.call({value: "sync"})).to eq("[sync]")
    pending.complete(work.call)
    pending.mark_physical_complete!
    expect(async.wait_result).to eq("[async]")
    expect(async.physical_complete?).to be(true)
    expect(seen.map(&:first)).to eq(["sync", "async"])
  end

  it "keeps concurrent offloaded invocations and their arguments independent" do
    install_super
    instance = decorate.new
    submissions = []
    allow(Phronomy::Execution).to receive(:submit) do |**kwargs, &work|
      source = Phronomy::Concurrency::PhysicalCompletionTask.deferred
      submissions << [source, work]
      source
    end
    first = instance.call_async({value: "first"})
    second = instance.call_async({value: "second"})
    submissions.reverse_each do |source, work|
      source.complete(work.call)
      source.mark_physical_complete!
    end
    expect(first.wait_result).to eq("[first]")
    expect(second.wait_result).to eq("[second]")
    expect(seen.map { |value, _, args| [value, args[:value]] }).to eq([["second", "second"], ["first", "first"]])
  end

  it "preserves duplicate Agent filter registrations and their order" do
    tool_class.execution_mode :cooperative
    install_super
    events = []
    repeated = ->(value, **kwargs) {
      events << value
      "[#{value}]"
    }
    last = ->(value, **kwargs) { "last:#{value}" }
    prepared = Phronomy::Agent::ToolBinding.new(tool_class, alias_name: "bound")
      .prepare(result_filters: [repeated, repeated, last])
    expect(prepared.new.call_async({value: "x"}).wait_result).to eq("last:[[x]]")
    expect(events).to eq(["x", "[x]"])
  end

  it "preserves argument and cancellation-token identity across the bridge" do
    tool_class.execution_mode :cooperative
    received = nil
    tool_class.define_method(:call) do |args, cancellation_token: nil|
      received = [args, cancellation_token]
      args[:value]
    end
    install_super
    args = {value: "x"}.freeze
    token = Phronomy::Concurrency::CancellationToken.new
    expect(decorate.new.call_async(args, cancellation_token: token).wait_result).to eq("[x]")
    expect(received.first).to be(args)
    expect(received.last).to be(token)
  end

  it "does not transform a failed delegated call and preserves the failure object" do
    tool_class.execution_mode :cooperative
    error = Phronomy::ToolError.new("execution failed")
    tool_class.define_method(:call) { |*args, **kwargs| raise error }
    install_super
    result = decorate.new.call_async({value: "x"})
    expect { result.wait_result }.to raise_error { |actual| expect(actual).to be(error) }
    expect(seen).to be_empty
  end

  it "preserves a transform failure without poisoning later calls" do
    tool_class.execution_mode :cooperative
    install_super
    error = RuntimeError.new("filter failed")
    instance = decorate { |value, *|
      raise error if value == "bad"
      "[#{value}]"
    }.new
    result = instance.call_async({value: "bad"})
    expect { result.wait_result }.to raise_error { |actual| expect(actual).to be(error) }
    expect(instance.call_async({value: "good"}).wait_result).to eq("[good]")
    expect(instance.call({value: "good"})).to eq("[good]")
  end

  it "preserves source cancellation and physical completion through delegated work" do
    install_super
    source = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    work = nil
    allow(Phronomy::Execution).to receive(:submit) { |**kwargs, &block|
      work = block
      source
    }
    result = decorate.new.call_async({value: "late"})
    error = Phronomy::CancellationError.new("cancelled")
    source.cancel!(error)
    expect { result.wait_result }.to raise_error { |actual| expect(actual).to be(error) }
    expect(result.physical_complete?).to be(false)
    work.call
    source.mark_physical_complete!
    expect(result.physical_complete?).to be(true)
    expect(seen).to be_empty
  end

  it "does not report physical completion before a delegated result's filter returns" do
    install_super
    pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 2)
    started = Queue.new
    release = Queue.new
    allow(Phronomy::Execution).to receive(:submit) { |**kwargs, &work| pool.submit(**kwargs, &work) }
    instance = decorate do |value, *|
      started << true
      release.pop
      "[#{value}]"
    end.new
    # Keep completion asynchronous until the result adapter has subscribed.
    source_release = Queue.new
    tool_class.define_method(:execute) { |value:|
      source_release.pop
      value
    }
    result = instance.call_async({value: "x"})
    source_release << true
    Timeout.timeout(3) { started.pop }
    expect(result.physical_complete?).to be(false)
    expect(result.done?).to be(false)
    release << true
    expect(result.wait_result(timeout: 3)).to eq("[x]")
    completed = Queue.new
    result.on_physical_complete { completed << true }
    expect(Timeout.timeout(3) { completed.pop }).to be(true)
  ensure
    source_release << true if source_release
    release << true if release
    pool&.shutdown(drain_timeout: 1)
  end
end
