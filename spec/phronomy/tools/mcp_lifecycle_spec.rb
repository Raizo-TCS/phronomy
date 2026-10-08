# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tools::Mcp, "connection lifecycle" do
  let(:response) { {"result" => {"content" => [{"type" => "text", "text" => "ok"}]}} }
  let(:transport) { instance_double(MCP::Client::Stdio, close: nil) }
  let(:client) { instance_double(MCP::Client, connect: nil, transport: transport, call_tool: response) }
  let(:token) { Phronomy::Concurrency::CancellationToken.new }
  let(:tool) do
    definition = instance_double(MCP::Client::Tool, name: "search", description: "Search",
      input_schema: {"type" => "object", "properties" => {}}, output_schema: nil)
    discovery = instance_double(MCP::Client, connect: nil, tools: [definition])
    discovery_transport = instance_double(MCP::Client::Stdio, close: nil)
    allow(MCP::Client::Stdio).to receive(:new).and_return(discovery_transport, transport)
    allow(MCP::Client).to receive(:new).and_return(discovery, client)
    Phronomy::Tools::Mcp.from_server("stdio://review-server", tool_name: "search")
  end

  def await_signal(queue)
    queue.pop(timeout: 2) || raise("MCP lifecycle test barrier timed out")
  end

  # Inspection is limited to checking retention on the caller-owned token.
  # The behavior assertions also cancel it after the operation has ended.
  def registrations(token)
    token.instance_variable_get(:@cancel_callbacks).size
  end

  it "releases successful registrations without removing another token subscriber" do
    received = []
    other_calls = 0
    token.on_cancel { other_calls += 1 }
    allow(client).to receive(:call_tool) do |**options|
      received << options.fetch(:cancellation)
      response
    end
    100.times { expect(tool.execute(cancellation_token: token)).to eq("ok") }
    expect(registrations(token)).to eq(1)
    token.cancel!
    expect(other_calls).to eq(1)
    expect(received.none?(&:cancelled?)).to be(true)
  end

  {
    "SDK failure" => -> { raise MCP::Client::ServerError.new("failed", code: -32_600) },
    "malformed response" => -> { {} }
  }.each do |label, result|
    it "releases the registration after #{label}" do
      received = nil
      allow(client).to receive(:call_tool) do |**options|
        received = options.fetch(:cancellation)
        result.call
      end
      expect { tool.execute(cancellation_token: token) }.to raise_error(Phronomy::ToolError)
      expect(registrations(token)).to eq(0)
      token.cancel!
      expect(received).not_to be_cancelled
    end
  end

  it "releases the registration when the SDK reports cancellation independently" do
    allow(client).to receive(:call_tool).and_raise(MCP::CancelledError.new(reason: "remote"))
    allow(Phronomy::Execution).to receive(:submit).and_raise(Phronomy::BackpressureError)
    expect { tool.execute(cancellation_token: token) }.to raise_error(Phronomy::CancellationError, /remote/)
    expect(registrations(token)).to eq(0)
    expect(transport).to have_received(:close).once
  end

  it "passes an already cancelled token to the SDK without retaining a registration" do
    token.cancel!
    allow(client).to receive(:call_tool) do |**options|
      expect(options.fetch(:cancellation)).to be_cancelled
      response
    end
    expect(tool.execute(cancellation_token: token)).to eq("ok")
    expect(registrations(token)).to eq(0)
  end

  it "keeps the bridge explicit-only and does not promote an elapsed deadline" do
    expired = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
    expect(Phronomy::Execution).not_to receive(:after)
    allow(client).to receive(:call_tool) do |**options|
      expect(options.fetch(:cancellation)).not_to be_cancelled
      response
    end
    tool.execute(cancellation_token: expired)
    expect(registrations(expired)).to eq(0)
  end

  it "retains SDK cancellation after logical timeout until physical execution ends" do
    clock = 0.0
    timer = Phronomy::Runtime::TimerQueue.new(clock: -> { clock })
    pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 1,
      timer_queue_provider: -> { timer })
    entered = Queue.new
    release = Queue.new
    received = nil
    allow(client).to receive(:call_tool) do |**options|
      received = options.fetch(:cancellation)
      entered << true
      await_signal(release)
      response
    end
    instance = tool
    task = pool.submit(timeout: 1, cancellation_token: token) { instance.execute(cancellation_token: token) }
    await_signal(entered)
    clock = 2.0
    timer.fire_due
    expect { task.wait_result(timeout: 1) }.to raise_error(Phronomy::TimeoutError)
    expect(task).not_to be_physical_complete
    expect(registrations(token)).to eq(1)
    token.cancel!
    expect(received).to be_cancelled
    release << true
    pool.shutdown(drain_timeout: 2)
    expect(pool).to be_terminated
    expect(task).to be_physical_complete
    expect(registrations(token)).to eq(0)
  ensure
    release << true if release
    pool&.shutdown(drain_timeout: 2)
  end

  it "tolerates cancellation already taken for delivery when the SDK call completes" do
    delivering = Queue.new
    release_delivery = Queue.new
    entered = Queue.new
    release_call = Queue.new
    token.on_cancel do
      delivering << true
      await_signal(release_delivery)
    end
    received = nil
    allow(client).to receive(:call_tool) do |**options|
      received = options.fetch(:cancellation)
      entered << true
      await_signal(release_call)
      response
    end
    instance = tool
    calling = Thread.new { instance.execute(cancellation_token: token) }
    await_signal(entered)
    cancelling = Thread.new { token.cancel! }
    await_signal(delivering)
    release_call << true
    expect(calling.join(2)).not_to be_nil
    expect(calling.value).to eq("ok")
    expect(received).not_to be_cancelled
    release_delivery << true
    expect(cancelling.join(2)).not_to be_nil
    cancelling.value
    expect(received).to be_cancelled
    expect(registrations(token)).to eq(0)
  ensure
    release_call << true
    release_delivery << true
    calling&.join(2)
    cancelling&.join(2)
  end

  it "closes a detached transport when the call returns cancellation after Runtime stops" do
    entered = Queue.new
    release = Queue.new
    allow(client).to receive(:call_tool) do
      entered << true
      await_signal(release)
      raise MCP::CancelledError.new(reason: "shutdown-window")
    end
    runtime = Phronomy::Runtime.instance
    instance = tool
    calling = Thread.new do
      instance.execute(cancellation_token: token)
    rescue => error
      error
    end
    await_signal(entered)
    expect(runtime.shutdown(timeout: 0, cancel_grace: 0).cleanup_complete?).to be(true)
    release << true
    expect(calling.join(2)).not_to be_nil
    expect(calling.value).to be_a(Phronomy::CancellationError)
    expect(calling.value.message).to include("shutdown-window")
    expect(transport).to have_received(:close).once
    expect(registrations(token)).to eq(0)
    instance.close
    expect(transport).to have_received(:close).once
  ensure
    release << true
    calling&.join(2)
  end

  it "leaves accepted cleanup with Runtime and closes the detached transport once" do
    closing = Queue.new
    release = Queue.new
    allow(client).to receive(:call_tool).and_raise(MCP::CancelledError.new(reason: "accepted-cleanup"))
    allow(transport).to receive(:close) do
      closing << true
      await_signal(release)
    end
    instance = tool
    expect { instance.execute(cancellation_token: token) }.to raise_error(Phronomy::CancellationError, /accepted-cleanup/)
    await_signal(closing)
    expect(registrations(token)).to eq(0)
    instance.close
    release << true
    expect(Phronomy::Runtime.instance.shutdown.cleanup_complete?).to be(true)
    expect(transport).to have_received(:close).once
  ensure
    release << true
  end

  [Phronomy::BackpressureError, Phronomy::PoolShutdownError, Phronomy::RuntimeShutdownError].each do |failure|
    it "closes the transport if cleanup submission raises #{failure}" do
      allow(client).to receive(:call_tool).and_raise(MCP::CancelledError.new(reason: "cancelled"))
      allow(Phronomy::Execution).to receive(:submit).and_raise(failure)
      expect { tool.execute(cancellation_token: token) }.to raise_error(Phronomy::CancellationError, /cancelled/)
      expect(transport).to have_received(:close).once
      expect(registrations(token)).to eq(0)
    end
  end

  it "does not replace the cancellation outcome if fallback transport close fails" do
    allow(client).to receive(:call_tool).and_raise(MCP::CancelledError.new(reason: "original"))
    allow(Phronomy::Execution).to receive(:submit).and_raise(Phronomy::RuntimeShutdownError)
    allow(transport).to receive(:close).and_raise(IOError, "already closed")
    expect { tool.execute(cancellation_token: token) }.to raise_error(Phronomy::CancellationError, /original/)
    expect(transport).to have_received(:close).once
    expect(registrations(token)).to eq(0)
  end

  it "uses the current neutral logger without reading the application facade" do
    first = instance_double(Logger, warn: nil)
    second = instance_double(Logger, warn: nil)
    settings = Phronomy::RuntimeSettings.new
    RSpec::Mocks.with_temporary_scope do
      allow(Phronomy::RuntimeSettings).to receive(:current).and_return(settings)
      expect(Phronomy).not_to receive(:configuration)
      settings.logger = first
      Phronomy::Tools::Mcp.send(:warn_mcp, "first")
      settings.logger = second
      Phronomy::Tools::Mcp.send(:warn_mcp, "second")
      expect(first).to have_received(:warn).with("first").once
      expect(second).to have_received(:warn).with("second").once
    end
  end

  it "preserves stderr warnings when the neutral logger is absent" do
    settings = Phronomy::RuntimeSettings.new
    RSpec::Mocks.with_temporary_scope do
      allow(Phronomy::RuntimeSettings).to receive(:current).and_return(settings)
      expect(Phronomy).not_to receive(:configuration)
      expect { Phronomy::Tools::Mcp.send(:warn_mcp, "no logger") }.to output("no logger\n").to_stderr
    end
  end
end
