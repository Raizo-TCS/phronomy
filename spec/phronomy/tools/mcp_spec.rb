# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tools::Mcp do
  it "is a subclass of Phronomy::Agent::Context::Capability::Base" do
    expect(described_class).to be < Phronomy::Agent::Context::Capability::Base
  end

  # Build a MCP::Client::Tool double.
  def mcp_tool_double(name:, description:, properties: {}, required: [],
    input_schema: nil, output_schema: nil, additional_properties: :__unset__)
    schema = input_schema || {
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
    unless additional_properties == :__unset__
      schema["additionalProperties"] = additional_properties
    end

    instance_double(MCP::Client::Tool,
      name: name,
      description: description,
      input_schema: schema,
      output_schema: output_schema)
  end

  # Stub MCP::Client::Stdio and MCP::Client so that from_server uses discovery_client
  # for tool discovery and instance_client for the live instance.
  def stub_stdio(discovery_client:, instance_client:)
    transport_dbl = instance_double(MCP::Client::Stdio, close: nil)
    allow(MCP::Client::Stdio).to receive(:new).and_return(transport_dbl)
    allow(MCP::Client).to receive(:new).and_return(discovery_client, instance_client)
  end

  # Stub MCP::Client::HTTP and MCP::Client similarly.
  def stub_http(discovery_client:, instance_client:)
    transport_dbl = instance_double(MCP::Client::HTTP, close: nil)
    allow(MCP::Client::HTTP).to receive(:new).and_return(transport_dbl)
    allow(MCP::Client).to receive(:new).and_return(discovery_client, instance_client)
  end

  describe ".from_server" do
    it "raises ArgumentError for unsupported transport schemes" do
      expect {
        described_class.from_server("grpc://localhost:9000", tool_name: "search")
      }.to raise_error(ArgumentError, /grpc/)
    end

    context "with a mocked stdio server" do
      let(:search_tool) do
        mcp_tool_double(
          name: "search_web", description: "Search the web",
          properties: {
            "query" => {"type" => "string", "description" => "Search query"},
            "limit" => {"type" => "integer", "description" => "Max results"}
          }
        )
      end
      let(:discovery_client) { instance_double(MCP::Client, connect: nil, tools: [search_tool]) }
      let(:instance_transport) { instance_double(MCP::Client::Stdio, close: nil) }
      let(:instance_client) do
        instance_double(MCP::Client, connect: nil, transport: instance_transport,
          call_tool: {"result" => {"content" => [{"type" => "text", "text" => "result"}]}})
      end

      before { stub_stdio(discovery_client: discovery_client, instance_client: instance_client) }

      subject(:tool_instance) do
        described_class.from_server("stdio://./mcp-server", tool_name: "search_web")
      end

      it "returns a Mcp instance" do
        expect(tool_instance).to be_a(Phronomy::Tools::Mcp)
      end

      it "sets the description from the server response" do
        expect(tool_instance.class.description).to eq("Search the web")
      end

      it "registers parameters from the server schema" do
        param_names = tool_instance.class.parameters.keys.map(&:to_s)
        expect(param_names).to include("query", "limit")
      end

      it "delegates #execute to the MCP client call_tool" do
        result = tool_instance.execute(query: "Ruby")
        expect(result).to eq("result")
      end

      it "delegates #close to the instance transport" do
        tool_instance.close
        expect(instance_transport).to have_received(:close)
      end
    end

    context "when tool is not found on the server" do
      let(:discovery_client) { instance_double(MCP::Client, connect: nil, tools: []) }

      before do
        transport_dbl = instance_double(MCP::Client::Stdio, close: nil)
        allow(MCP::Client::Stdio).to receive(:new).and_return(transport_dbl)
        allow(MCP::Client).to receive(:new).and_return(discovery_client)
      end

      it "raises ArgumentError and still closes the short-lived transport via ensure" do
        expect {
          described_class.from_server("stdio://./mcp-server", tool_name: "missing")
        }.to raise_error(ArgumentError, /missing/)
      end
    end
  end

  describe "Stdio transport (via from_server)" do
    let(:search_tool) do
      mcp_tool_double(
        name: "search", description: "Search tool",
        properties: {"query" => {"type" => "string", "description" => "The query"}}
      )
    end
    let(:discovery_client) { instance_double(MCP::Client, connect: nil, tools: [search_tool]) }
    let(:instance_transport) { instance_double(MCP::Client::Stdio, close: nil) }
    let(:instance_client) { instance_double(MCP::Client, connect: nil, transport: instance_transport) }

    before { stub_stdio(discovery_client: discovery_client, instance_client: instance_client) }

    it "parses parameters from the server schema" do
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      param_names = tool.class.parameters.keys.map(&:to_s)
      expect(param_names).to include("query")
    end

    it "raises ArgumentError when the tool is not found on the server" do
      allow(discovery_client).to receive(:tools).and_return([])
      expect {
        described_class.from_server("stdio://./mcp-server", tool_name: "missing")
      }.to raise_error(ArgumentError, /missing/)
    end

    it "extracts text from a single MCP content block" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {"content" => [{"type" => "text", "text" => "hello"}]}}
      )
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect(tool.execute(query: "hi")).to eq("hello")
    end

    it "returns an array when there are multiple text blocks" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {"content" => [{"type" => "text", "text" => "a"}, {"type" => "text", "text" => "b"}]}}
      )
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect(tool.execute(query: "hi")).to eq(["a", "b"])
    end

    it "raises ToolError when the MCP SDK raises ServerError" do
      allow(instance_client).to receive(:call_tool).and_raise(
        MCP::Client::ServerError.new("Internal error", code: -32_600)
      )
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect { tool.execute(query: "hi") }
        .to raise_error(Phronomy::ToolError, /-32600.*Internal error/)
    end

    it "splits 'command args' string into command: and args: for MCP::Client::Stdio" do
      allow(MCP::Client::Stdio).to receive(:new).and_return(instance_double(MCP::Client::Stdio, close: nil))
      described_class.from_server("stdio://node server.js", tool_name: "search")
      expect(MCP::Client::Stdio).to have_received(:new).with(
        command: "node", args: ["server.js"]
      ).at_least(:once)
    end
  end

  describe "HTTP transport (via from_server)" do
    let(:weather_tool) do
      mcp_tool_double(
        name: "weather", description: "Get weather",
        properties: {"city" => {"type" => "string", "description" => "City name"}}
      )
    end
    let(:discovery_client) { instance_double(MCP::Client, connect: nil, tools: [weather_tool]) }
    let(:instance_transport) { instance_double(MCP::Client::HTTP, close: nil) }
    let(:instance_client) { instance_double(MCP::Client, connect: nil, transport: instance_transport) }

    before { stub_http(discovery_client: discovery_client, instance_client: instance_client) }

    it "returns description and parameters from the server" do
      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      expect(tool.class.description).to eq("Get weather")
      param_names = tool.class.parameters.keys.map(&:to_s)
      expect(param_names).to include("city")
    end

    it "raises ArgumentError when the tool is not found" do
      allow(discovery_client).to receive(:tools).and_return([])
      expect {
        described_class.from_server("http://localhost:8080/mcp", tool_name: "missing")
      }.to raise_error(ArgumentError, /missing/)
    end

    it "extracts text from MCP content blocks" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {"content" => [{"type" => "text", "text" => "sunny"}]}}
      )
      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      expect(tool.execute(city: "Tokyo")).to eq("sunny")
    end

    it "returns an array when there are multiple text blocks" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {"content" => [{"type" => "text", "text" => "a"}, {"type" => "text", "text" => "b"}]}}
      )
      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      expect(tool.execute).to eq(["a", "b"])
    end

    it "dispatches http:// URIs to MCP::Client::HTTP" do
      described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      expect(MCP::Client::HTTP).to have_received(:new).at_least(:once)
    end

    it "dispatches https:// URIs to MCP::Client::HTTP" do
      allow(MCP::Client::HTTP).to receive(:new).and_return(instance_double(MCP::Client::HTTP, close: nil))
      tool = described_class.from_server("https://api.example.com/mcp", tool_name: "weather")
      expect(tool).to be_a(Phronomy::Tools::Mcp)
    end

    # Regression test for GitHub Issue #23 (ID-5):
    # ServerError is now raised by the SDK; legacy response["error"] pattern removed.
    it "raises ToolError when the MCP SDK raises a JSON-RPC ServerError" do
      allow(instance_client).to receive(:call_tool).and_raise(
        MCP::Client::ServerError.new("Invalid MCP request", code: -32_600)
      )
      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      expect { tool.execute(city: "Tokyo") }
        .to raise_error(Phronomy::ToolError, /-32600.*Invalid MCP request/)
    end

    it "returns an MCP tool-level error to the model as text" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {
          "content" => [{"type" => "text", "text" => "invalid city"}],
          "isError" => true
        }}
      )
      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      expect(tool.execute(city: "Tokyo"))
        .to eq("MCP tool execution error: invalid city")
    end
  end

  # Regression test for Issue #151: custom HTTP headers must be forwarded.
  describe "custom HTTP headers (Issue #151)" do
    let(:search_tool) { mcp_tool_double(name: "search", description: "Search") }
    let(:discovery_client) { instance_double(MCP::Client, connect: nil, tools: [search_tool]) }
    let(:instance_client) do
      instance_double(MCP::Client, connect: nil, transport: instance_double(MCP::Client::HTTP, close: nil))
    end

    it "passes custom headers to MCP::Client::HTTP for every connection" do
      http_transport = instance_double(MCP::Client::HTTP, close: nil)
      allow(MCP::Client::HTTP).to receive(:new).and_return(http_transport)
      allow(MCP::Client).to receive(:new).and_return(discovery_client, instance_client)

      described_class.from_server(
        "http://localhost:8080/mcp",
        tool_name: "search",
        headers: {"Authorization" => "Bearer secret", "X-Custom" => "value"}
      )

      expect(MCP::Client::HTTP).to have_received(:new).with(
        url: "http://localhost:8080/mcp",
        headers: {"Authorization" => "Bearer secret", "X-Custom" => "value"}
      ).at_least(:once)
    end
  end

  # CancellationToken → MCP::Cancellation bridge (Issue #390)
  describe "CancellationToken → MCP::Cancellation bridge" do
    let(:search_tool) { mcp_tool_double(name: "search", description: "Search") }
    let(:discovery_client) { instance_double(MCP::Client, connect: nil, tools: [search_tool]) }
    let(:instance_transport) { instance_double(MCP::Client::Stdio, close: nil) }
    let(:instance_client) { instance_double(MCP::Client, connect: nil, transport: instance_transport) }

    before { stub_stdio(discovery_client: discovery_client, instance_client: instance_client) }

    it "passes an MCP::Cancellation to call_tool when a CancellationToken is given" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {"content" => [{"type" => "text", "text" => "ok"}]}}
      )
      ct = Phronomy::Concurrency::CancellationToken.new
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      tool.execute(cancellation_token: ct, query: "test")
      expect(instance_client).to have_received(:call_tool).with(
        hash_including(cancellation: instance_of(MCP::Cancellation))
      )
    end

    it "cancels the MCP::Cancellation when cancel! is called on the CancellationToken" do
      received_cancellation = nil
      allow(instance_client).to receive(:call_tool) do |**kwargs|
        received_cancellation = kwargs[:cancellation]
        {"result" => {"content" => [{"type" => "text", "text" => "ok"}]}}
      end
      ct = Phronomy::Concurrency::CancellationToken.new
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      tool.execute(cancellation_token: ct, query: "test")
      ct.cancel!
      expect(received_cancellation).to be_cancelled
    end

    it "passes cancellation: nil when no CancellationToken is given" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {"content" => [{"type" => "text", "text" => "ok"}]}}
      )
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      tool.execute(query: "test")
      expect(instance_client).to have_received(:call_tool).with(
        hash_including(cancellation: nil)
      )
    end
  end

  describe "MCP v1 response validation" do
    let(:search_tool) { mcp_tool_double(name: "search", description: "Search") }
    let(:discovery_client) { instance_double(MCP::Client, connect: nil, tools: [search_tool]) }
    let(:instance_transport) { instance_double(MCP::Client::Stdio, close: nil) }
    let(:instance_client) { instance_double(MCP::Client, connect: nil, transport: instance_transport) }

    before { stub_stdio(discovery_client: discovery_client, instance_client: instance_client) }

    it "rejects a response without result" do
      allow(instance_client).to receive(:call_tool).and_return({})
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect { tool.execute(query: "x") }
        .to raise_error(Phronomy::ToolError, /missing a valid result/)
    end

    it "rejects non-array content" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"result" => {"content" => "invalid"}}
      )
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect { tool.execute(query: "x") }
        .to raise_error(Phronomy::ToolError, /missing valid content/)
    end
  end

  describe "MCP v1 schema compatibility" do
    it "preserves boolean enum values as booleans" do
      tool_def = mcp_tool_double(
        name: "toggle",
        description: "Toggle",
        properties: {
          "enabled" => {"type" => "boolean", "enum" => [true, false]}
        }
      )
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      live_transport = instance_double(MCP::Client::Stdio, close: nil)
      live_client = instance_double(MCP::Client, connect: nil, transport: live_transport)
      stub_stdio(discovery_client: discovery_client, instance_client: live_client)

      tool = described_class.from_server("stdio://./mcp-server", tool_name: "toggle")
      expect(tool.params_schema.dig("properties", "enabled", "enum"))
        .to eq([true, false])
    end

    it "rejects unknown root schema keywords" do
      tool_def = mcp_tool_double(
        name: "search",
        description: "Search",
        input_schema: {
          "type" => "object",
          "properties" => {},
          "allOf" => []
        }
      )
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      allow(MCP::Client::Stdio).to receive(:new)
        .and_return(instance_double(MCP::Client::Stdio, close: nil))
      allow(MCP::Client).to receive(:new).and_return(discovery_client)

      expect {
        described_class.from_server("stdio://./mcp-server", tool_name: "search")
      }.to raise_error(Phronomy::ToolError, /allOf/)
    end

    it "accepts omitted additionalProperties" do
      accepted = mcp_tool_double(name: "accepted", description: "Accepted")
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [accepted])
      live_transport = instance_double(MCP::Client::Stdio, close: nil)
      live_client = instance_double(MCP::Client, connect: nil, transport: live_transport)
      stub_stdio(discovery_client: discovery_client, instance_client: live_client)

      expect {
        described_class.from_server("stdio://./mcp-server", tool_name: "accepted")
      }.not_to raise_error
    end

    it "rejects additionalProperties: true" do
      rejected = mcp_tool_double(
        name: "rejected", description: "Rejected", additional_properties: true
      )
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [rejected])
      allow(MCP::Client::Stdio).to receive(:new)
        .and_return(instance_double(MCP::Client::Stdio, close: nil))
      allow(MCP::Client).to receive(:new).and_return(discovery_client)

      expect {
        described_class.from_server("stdio://./mcp-server", tool_name: "rejected")
      }.to raise_error(Phronomy::ToolError, /additionalProperties/)
    end
  end

  describe "MCP client lifecycle" do
    it "reconnects after explicit close" do
      tool_def = mcp_tool_double(name: "search", description: "Search")
      discovery_transport = instance_double(MCP::Client::Stdio, close: nil)
      first_transport = instance_double(MCP::Client::Stdio, close: nil)
      second_transport = instance_double(MCP::Client::Stdio, close: nil)
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      first_client = instance_double(MCP::Client, connect: nil, transport: first_transport)
      second_client = instance_double(
        MCP::Client,
        connect: nil,
        transport: second_transport,
        call_tool: {"result" => {"content" => [{"type" => "text", "text" => "ok"}]}}
      )
      allow(MCP::Client::Stdio).to receive(:new)
        .and_return(discovery_transport, first_transport, second_transport)
      allow(MCP::Client).to receive(:new)
        .and_return(discovery_client, first_client, second_client)

      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      tool.close
      expect(tool.execute(query: "x")).to eq("ok")
      expect(first_transport).to have_received(:close)
      expect(second_client).to have_received(:connect)
    end

    it "restores an expired HTTP session without replaying the failed call" do
      tool_def = mcp_tool_double(name: "search", description: "Search")
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      live_transport = instance_double(MCP::Client::HTTP, close: nil)
      live_client = instance_double(MCP::Client, transport: live_transport)
      allow(live_client).to receive(:connect).twice.and_return(nil)
      allow(live_client).to receive(:call_tool)
        .and_raise(MCP::Client::SessionExpiredError.new("expired", nil))
      stub_http(discovery_client: discovery_client, instance_client: live_client)

      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "search")
      expect { tool.execute(query: "x") }
        .to raise_error(Phronomy::ToolError, /was not replayed/)
      expect(live_client).to have_received(:call_tool).once
      expect(live_client).to have_received(:connect).twice
    end

    it "converts MCP::CancelledError to Phronomy::CancellationError and preserves reason" do
      tool_def = mcp_tool_double(name: "search", description: "Search")
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      live_transport = instance_double(MCP::Client::Stdio, close: nil)
      live_client = instance_double(MCP::Client, connect: nil, transport: live_transport)
      allow(live_client).to receive(:call_tool)
        .and_raise(MCP::CancelledError.new(reason: "phronomy_cancelled"))
      allow(MCP::Client::Stdio).to receive(:new).and_return(live_transport, live_transport)
      allow(MCP::Client).to receive(:new).and_return(discovery_client, live_client)
      # Prevent async cleanup spawn from failing in unit test context
      allow(Phronomy::Runtime.instance).to receive(:pool).and_call_original

      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect { tool.execute(query: "test") }
        .to raise_error(Phronomy::CancellationError, /phronomy_cancelled/)
    end

    it "creates a new client after cancellation (does not reuse invalidated transport)" do
      tool_def = mcp_tool_double(name: "search", description: "Search")
      discovery_transport = instance_double(MCP::Client::Stdio, close: nil)
      cancelled_transport = instance_double(MCP::Client::Stdio, close: nil)
      replacement_transport = instance_double(MCP::Client::Stdio, close: nil)
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      cancelled_client = instance_double(MCP::Client, connect: nil, transport: cancelled_transport)
      replacement_client = instance_double(
        MCP::Client,
        connect: nil,
        transport: replacement_transport,
        call_tool: {"result" => {"content" => [{"type" => "text", "text" => "new"}]}}
      )
      allow(cancelled_client).to receive(:call_tool)
        .and_raise(MCP::CancelledError.new(reason: "test"))
      allow(MCP::Client::Stdio).to receive(:new)
        .and_return(discovery_transport, cancelled_transport, replacement_transport)
      allow(MCP::Client).to receive(:new)
        .and_return(discovery_client, cancelled_client, replacement_client)
      allow(Phronomy::Runtime.instance).to receive(:pool).and_call_original

      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect { tool.execute(query: "first") }.to raise_error(Phronomy::CancellationError, /test/)
      expect(tool.execute(query: "second")).to eq("new")
      expect(replacement_client).to have_received(:connect)
    end

    it "invalidates the client when session reconnection fails (does not reuse broken client)" do
      tool_def = mcp_tool_double(name: "search", description: "Search")
      discovery_transport = instance_double(MCP::Client::HTTP, close: nil)
      broken_transport = instance_double(MCP::Client::HTTP, close: nil)
      fresh_transport = instance_double(MCP::Client::HTTP, close: nil)
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      broken_client = instance_double(MCP::Client, transport: broken_transport)
      fresh_client = instance_double(
        MCP::Client,
        connect: nil,
        transport: fresh_transport,
        call_tool: {"result" => {"content" => [{"type" => "text", "text" => "recovered"}]}}
      )
      # First connect succeeds (initialisation), second (reconnect after expiry) fails
      connect_calls = 0
      allow(broken_client).to receive(:connect) do
        connect_calls += 1
        raise "reconnect failed" if connect_calls > 1

        nil
      end
      allow(broken_client).to receive(:call_tool)
        .and_raise(MCP::Client::SessionExpiredError.new("expired", nil))
      allow(MCP::Client::HTTP).to receive(:new)
        .and_return(discovery_transport, broken_transport, fresh_transport)
      allow(MCP::Client).to receive(:new)
        .and_return(discovery_client, broken_client, fresh_client)

      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "search")
      expect { tool.execute(query: "first") }
        .to raise_error(Phronomy::ToolError, /reconnection failed/)
      # Second call must use fresh_client, not broken_client
      expect(tool.execute(query: "second")).to eq("recovered")
      expect(fresh_client).to have_received(:connect)
    end

    it "does not freeze the caller-provided headers hash" do
      headers = {"Authorization" => "Bearer secret"}
      tool_def = mcp_tool_double(name: "search", description: "Search")
      discovery_client = instance_double(MCP::Client, connect: nil, tools: [tool_def])
      instance_client = instance_double(MCP::Client, connect: nil, transport: instance_double(MCP::Client::HTTP, close: nil))
      stub_http(discovery_client: discovery_client, instance_client: instance_client)

      described_class.from_server(
        "http://localhost:8080/mcp",
        tool_name: "search",
        headers: headers
      )

      expect { headers["X-New"] = "value" }.not_to raise_error
    end
  end
end
