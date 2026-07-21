# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tools::Mcp do
  it "is a subclass of Phronomy::Agent::Context::Capability::Base" do
    expect(described_class).to be < Phronomy::Agent::Context::Capability::Base
  end

  # Build a MCP::Client::Tool double.
  def mcp_tool_double(name:, description:, properties: {}, required: [])
    instance_double(MCP::Client::Tool,
      name: name,
      description: description,
      input_schema: {"properties" => properties, "required" => required})
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

    it "raises ToolError when the server returns a JSON-RPC error response" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"error" => {"code" => -32600, "message" => "Internal error"}}
      )
      tool = described_class.from_server("stdio://./mcp-server", tool_name: "search")
      expect { tool.execute(query: "hi") }.to raise_error(Phronomy::ToolError)
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
    # call_tool must check for JSON-RPC error field and raise ToolError instead of returning nil.
    it "raises ToolError when the server returns a JSON-RPC error object in a 200 OK response" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"error" => {"code" => -32600, "message" => "Invalid MCP request"}}
      )
      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      expect { tool.execute(city: "Tokyo") }
        .to raise_error(Phronomy::ToolError, /Invalid MCP request/)
    end

    it "does not return nil silently when JSON-RPC error is present" do
      allow(instance_client).to receive(:call_tool).and_return(
        {"error" => {"code" => -32601, "message" => "Method not found"}}
      )
      tool = described_class.from_server("http://localhost:8080/mcp", tool_name: "weather")
      result = begin
        tool.execute
      rescue Phronomy::ToolError
        :raised
      end
      expect(result).to eq(:raised)
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
end
