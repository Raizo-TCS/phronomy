# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tool::McpTool do
  it "is a subclass of Phronomy::Tool::Base" do
    expect(described_class).to be < Phronomy::Tool::Base
  end

  describe ".from_server" do
    it "raises ArgumentError for unsupported transport schemes" do
      expect {
        described_class.from_server("grpc://localhost:9000", tool_name: "search")
      }.to raise_error(ArgumentError, /grpc/)
    end

    context "with a mocked stdio transport" do
      let(:transport_double) do
        instance_double(Phronomy::Tool::McpTool::StdioTransport).tap do |t|
          allow(t).to receive(:fetch_tool).with("search_web").and_return(
            description: "Search the web",
            parameters: [
              {name: "query", type: "string", description: "Search query"},
              {name: "limit", type: "integer", description: "Max results"}
            ]
          )
          allow(t).to receive(:call_tool).with("search_web", {query: "Ruby"}).and_return(["result"])
          allow(t).to receive(:close)
        end
      end

      before do
        allow(Phronomy::Tool::McpTool::StdioTransport).to receive(:new).and_return(transport_double)
      end

      subject(:tool_instance) do
        described_class.from_server("stdio://./mcp-server", tool_name: "search_web")
      end

      it "returns a McpTool instance" do
        expect(tool_instance).to be_a(Phronomy::Tool::McpTool)
      end

      it "sets the description from the server response" do
        expect(tool_instance.class.description).to eq("Search the web")
      end

      it "registers parameters from the server schema" do
        param_names = tool_instance.class.parameters.keys.map(&:to_s)
        expect(param_names).to include("query", "limit")
      end

      it "delegates #execute to the transport" do
        result = tool_instance.execute(query: "Ruby")
        expect(result).to eq(["result"])
      end

      it "delegates #close to the instance transport" do
        allow(transport_double).to receive(:close)
        tool_instance.close
        # transport_double backs both the short-lived from_server transport and
        # the instance transport (StdioTransport.new always returns it in this
        # context), so close is called at least once for the instance transport.
        expect(transport_double).to have_received(:close).at_least(:once)
      end
    end

    context "when fetch_tool raises" do
      let(:failing_transport) do
        instance_double(Phronomy::Tool::McpTool::StdioTransport).tap do |t|
          allow(t).to receive(:fetch_tool).and_raise(ArgumentError, "tool not found")
          allow(t).to receive(:close)
        end
      end

      before do
        allow(Phronomy::Tool::McpTool::StdioTransport).to receive(:new).and_return(failing_transport)
      end

      it "still closes the short-lived transport via ensure" do
        expect {
          described_class.from_server("stdio://./mcp-server", tool_name: "missing")
        }.to raise_error(ArgumentError, /tool not found/)
        expect(failing_transport).to have_received(:close).once
      end
    end
  end

  describe Phronomy::Tool::McpTool::StdioTransport do
    subject(:transport) { described_class.new("./echo-server") }

    # Helper: stub Open3.popen3 to return IO doubles that respond with one JSON line
    def stub_popen3_response(json_hash)
      json_line = JSON.generate(json_hash)
      stdin_dbl = instance_double(IO, puts: nil, closed?: false, close: nil)
      stdout_dbl = instance_double(IO)
      allow(stdout_dbl).to receive(:gets).and_return("#{json_line}\n")
      allow(stdout_dbl).to receive(:closed?).and_return(false)
      allow(stdout_dbl).to receive(:close)
      stderr_dbl = instance_double(IO, closed?: false, close: nil)
      wait_thr = double("wait_thr")
      allow(Open3).to receive(:popen3).and_return([stdin_dbl, stdout_dbl, stderr_dbl, wait_thr])
    end

    describe "#fetch_tool" do
      it "raises ArgumentError when the tool is not found on the server" do
        stub_popen3_response({"jsonrpc" => "2.0", "id" => "x", "result" => {"tools" => []}})
        expect { transport.fetch_tool("missing") }.to raise_error(ArgumentError, /missing/)
      end

      it "parses parameters from the server response" do
        schema = {
          "jsonrpc" => "2.0", "id" => "x",
          "result" => {
            "tools" => [{
              "name" => "search",
              "description" => "Search tool",
              "inputSchema" => {
                "properties" => {
                  "query" => {"type" => "string", "description" => "The query"}
                }
              }
            }]
          }
        }
        stub_popen3_response(schema)

        result = transport.fetch_tool("search")
        expect(result[:description]).to eq("Search tool")
        expect(result[:parameters].first[:name]).to eq("query")
      end
    end

    describe "#call_tool" do
      it "extracts text from MCP content blocks" do
        response = {
          "jsonrpc" => "2.0", "id" => "x",
          "result" => {
            "content" => [{"type" => "text", "text" => "hello"}]
          }
        }
        stub_popen3_response(response)

        expect(transport.call_tool("search", {query: "hi"})).to eq("hello")
      end

      it "raises ToolError when the server returns an error response" do
        error_resp = {
          "jsonrpc" => "2.0", "id" => "x",
          "error" => {"code" => -32600, "message" => "Internal error"}
        }
        stub_popen3_response(error_resp)
        expect { transport.call_tool("search", {}) }.to raise_error(Phronomy::ToolError)
      end
    end
  end

  describe Phronomy::Tool::McpTool::HttpTransport do
    subject(:transport) { described_class.new("http://localhost:8080/mcp") }

    def ok_response(body, content_type: "application/json")
      res = Net::HTTPSuccess.new("1.1", "200", "OK")
      allow(res).to receive(:body).and_return(body)
      allow(res).to receive(:[]).with("Content-Type").and_return(content_type)
      res
    end

    def stub_http(response)
      http_dbl = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_dbl)
      allow(http_dbl).to receive(:use_ssl=)
      allow(http_dbl).to receive(:open_timeout=)
      allow(http_dbl).to receive(:read_timeout=)
      allow(http_dbl).to receive(:request).and_return(response)
    end

    describe "#fetch_tool" do
      it "returns description and parameters from a JSON response" do
        body = JSON.generate(
          jsonrpc: "2.0", id: 1,
          result: {
            tools: [{
              name: "weather",
              description: "Get weather",
              inputSchema: {
                properties: {
                  city: {type: "string", description: "City name"}
                }
              }
            }]
          }
        )
        stub_http(ok_response(body))

        result = transport.fetch_tool("weather")
        expect(result[:description]).to eq("Get weather")
        expect(result[:parameters].first[:name]).to eq("city")
      end

      it "raises ArgumentError when the tool is not found" do
        body = JSON.generate(jsonrpc: "2.0", id: 1, result: {tools: []})
        stub_http(ok_response(body))

        expect { transport.fetch_tool("missing") }.to raise_error(ArgumentError, /missing/)
      end

      it "parses a JSON-RPC result from an SSE response" do
        rpc = JSON.generate(
          jsonrpc: "2.0", id: 1,
          result: {tools: [{name: "x", description: "X", inputSchema: {properties: {}}}]}
        )
        sse_body = "data: #{rpc}\n\n"
        stub_http(ok_response(sse_body, content_type: "text/event-stream"))

        result = transport.fetch_tool("x")
        expect(result[:description]).to eq("X")
      end
    end

    describe "#call_tool" do
      it "sends configured headers on JSON-RPC requests" do
        transport = described_class.new(
          "http://localhost:8080/mcp",
          headers: {"Authorization" => "Bearer test-token", "X-MCP-Client" => "phronomy"}
        )
        body = JSON.generate(
          jsonrpc: "2.0", id: 1,
          result: {content: [{type: "text", text: "sunny"}]}
        )
        response = ok_response(body)
        captured_request = nil

        http_dbl = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http_dbl)
        allow(http_dbl).to receive(:use_ssl=)
        allow(http_dbl).to receive(:open_timeout=)
        allow(http_dbl).to receive(:read_timeout=)
        allow(http_dbl).to receive(:request) do |request|
          captured_request = request
          response
        end

        expect(transport.call_tool("weather", {})).to eq("sunny")
        expect(captured_request["Authorization"]).to eq("Bearer test-token")
        expect(captured_request["X-MCP-Client"]).to eq("phronomy")
      end

      it "extracts text from MCP content blocks" do
        body = JSON.generate(
          jsonrpc: "2.0", id: 1,
          result: {content: [{type: "text", text: "sunny"}]}
        )
        stub_http(ok_response(body))

        expect(transport.call_tool("weather", {city: "Tokyo"})).to eq("sunny")
      end

      it "returns an array when there are multiple text blocks" do
        body = JSON.generate(
          jsonrpc: "2.0", id: 1,
          result: {content: [
            {type: "text", text: "a"},
            {type: "text", text: "b"}
          ]}
        )
        stub_http(ok_response(body))

        expect(transport.call_tool("weather", {})).to eq(["a", "b"])
      end

      it "raises ToolError when the server returns a non-2xx status" do
        res = Net::HTTPInternalServerError.new("1.1", "500", "Internal Server Error")
        allow(res).to receive(:body).and_return("oops")
        allow(res).to receive(:code).and_return("500")
        stub_http(res)

        expect { transport.call_tool("weather", {}) }.to raise_error(Phronomy::ToolError, /500/)
      end

      it "raises ToolError when SSE stream contains no JSON-RPC response" do
        sse_body = "data: not-json\n\ndata: [DONE]\n\n"
        stub_http(ok_response(sse_body, content_type: "text/event-stream"))

        expect { transport.call_tool("weather", {}) }.to raise_error(Phronomy::ToolError, /SSE/)
      end
    end

    context "when building via .from_server" do
      let(:transport_double) do
        instance_double(described_class).tap do |t|
          allow(t).to receive(:fetch_tool).with("search").and_return(
            description: "Search",
            parameters: [{name: "q", type: "string", description: "Query"}]
          )
          allow(t).to receive(:call_tool).with("search", {q: "Ruby"}).and_return("result")
          allow(t).to receive(:close)
        end
      end

      before do
        allow(described_class).to receive(:new).and_return(transport_double)
      end

      it "dispatches http:// URIs to HttpTransport" do
        tool = Phronomy::Tool::McpTool.from_server("http://localhost:8080/mcp", tool_name: "search")
        expect(tool).to be_a(Phronomy::Tool::McpTool)
      end

      it "dispatches https:// URIs to HttpTransport" do
        tool = Phronomy::Tool::McpTool.from_server("https://api.example.com/mcp", tool_name: "search")
        expect(tool).to be_a(Phronomy::Tool::McpTool)
      end
    end
  end

  describe "StdioTransport process reuse (S01)" do
    subject(:transport) { Phronomy::Tool::McpTool::StdioTransport.new("./echo-server") }

    it "calls Open3.popen3 only once across multiple RPC calls" do
      json_line = JSON.generate(
        "jsonrpc" => "2.0", "id" => "x",
        "result" => {"content" => [{"type" => "text", "text" => "ok"}]}
      )
      stdin_dbl = instance_double(IO, puts: nil, closed?: false, close: nil)
      stdout_dbl = instance_double(IO, gets: "#{json_line}\n", closed?: false, close: nil)
      stderr_dbl = instance_double(IO, closed?: false, close: nil)
      wait_thr = double("wait_thr")
      allow(Open3).to receive(:popen3).once.and_return([stdin_dbl, stdout_dbl, stderr_dbl, wait_thr])

      transport.call_tool("search", {})
      transport.call_tool("search", {})
      expect(Open3).to have_received(:popen3).once
    end
  end

  describe "StdioTransport unique request IDs (S11)" do
    subject(:transport) { Phronomy::Tool::McpTool::StdioTransport.new("./echo-server") }

    it "uses different UUIDs for each RPC call" do
      sent_payloads = []
      json_line = JSON.generate(
        "jsonrpc" => "2.0", "id" => "x",
        "result" => {"content" => [{"type" => "text", "text" => "ok"}]}
      )
      stdin_dbl = instance_double(IO, closed?: false, close: nil)
      allow(stdin_dbl).to receive(:puts) { |payload| sent_payloads << JSON.parse(payload) }
      stdout_dbl = instance_double(IO, gets: "#{json_line}\n", closed?: false, close: nil)
      stderr_dbl = instance_double(IO, closed?: false, close: nil)
      wait_thr = double("wait_thr")
      allow(Open3).to receive(:popen3).and_return([stdin_dbl, stdout_dbl, stderr_dbl, wait_thr])

      transport.call_tool("search", {})
      transport.call_tool("search", {})

      ids = sent_payloads.map { |p| p["id"] }
      expect(ids.length).to eq(2)
      expect(ids.uniq.length).to eq(2)
      # IDs should look like UUIDs
      expect(ids.first).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  # Regression test for GitHub Issue #23 (ID-5):
  # HttpTransport#call_tool was missing the JSON-RPC error field check
  # that StdioTransport already had. This caused server errors to be
  # silently ignored and nil returned instead of raising ToolError.
  describe "HttpTransport JSON-RPC error response (Issue #23 / ID-5)" do
    subject(:transport) { Phronomy::Tool::McpTool::HttpTransport.new("http://localhost:8080/mcp") }

    def ok_response(body, content_type: "application/json")
      res = Net::HTTPSuccess.new("1.1", "200", "OK")
      allow(res).to receive(:body).and_return(body)
      allow(res).to receive(:[]).with("Content-Type").and_return(content_type)
      res
    end

    def stub_http(response)
      http_dbl = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_dbl)
      allow(http_dbl).to receive(:use_ssl=)
      allow(http_dbl).to receive(:open_timeout=)
      allow(http_dbl).to receive(:read_timeout=)
      allow(http_dbl).to receive(:request).and_return(response)
    end

    it "raises ToolError when the server returns a JSON-RPC error object in a 200 OK response" do
      body = JSON.generate(
        jsonrpc: "2.0", id: 1,
        error: {code: -32600, message: "Invalid MCP request"}
      )
      stub_http(ok_response(body))

      expect { transport.call_tool("weather", {city: "Tokyo"}) }
        .to raise_error(Phronomy::ToolError, /Invalid MCP request/)
    end

    it "does not return nil silently when JSON-RPC error is present" do
      body = JSON.generate(
        jsonrpc: "2.0", id: 1,
        error: {code: -32601, message: "Method not found"}
      )
      stub_http(ok_response(body))

      result = begin
        transport.call_tool("weather", {})
      rescue Phronomy::ToolError
        :raised
      end
      expect(result).to eq(:raised)
    end
  end

  describe "HttpTransport timeout configuration (S09)" do
    it "applies custom open_timeout and read_timeout to the Net::HTTP connection" do
      transport = Phronomy::Tool::McpTool::HttpTransport.new(
        "http://localhost:8080/mcp",
        open_timeout: 3,
        read_timeout: 15
      )
      http_dbl = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http_dbl)
      allow(http_dbl).to receive(:use_ssl=)
      allow(http_dbl).to receive(:open_timeout=)
      allow(http_dbl).to receive(:read_timeout=)
      body = JSON.generate(jsonrpc: "2.0", id: 1, result: {tools: []})
      res = Net::HTTPSuccess.new("1.1", "200", "OK")
      allow(res).to receive(:body).and_return(body)
      allow(res).to receive(:[]).with("Content-Type").and_return("application/json")
      allow(http_dbl).to receive(:request).and_return(res)

      expect { transport.fetch_tool("missing") }.to raise_error(ArgumentError)
      expect(http_dbl).to have_received(:open_timeout=).with(3)
      expect(http_dbl).to have_received(:read_timeout=).with(15)
    end
  end
end
