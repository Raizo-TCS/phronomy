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
    end
  end

  describe Phronomy::Tool::McpTool::StdioTransport do
    subject(:transport) { described_class.new("./echo-server") }

    describe "#fetch_tool" do
      it "raises ArgumentError when the tool is not found on the server" do
        allow(Open3).to receive(:capture3).and_return(
          [%({"jsonrpc":"2.0","id":1,"result":{"tools":[]}}), "", double(success?: true, exitstatus: 0)]
        )
        expect { transport.fetch_tool("missing") }.to raise_error(ArgumentError, /missing/)
      end

      it "parses parameters from the server response" do
        schema = {
          "jsonrpc" => "2.0", "id" => 1,
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
        allow(Open3).to receive(:capture3)
          .and_return([JSON.generate(schema), "", double(success?: true, exitstatus: 0)])

        result = transport.fetch_tool("search")
        expect(result[:description]).to eq("Search tool")
        expect(result[:parameters].first[:name]).to eq("query")
      end
    end

    describe "#call_tool" do
      it "extracts text from MCP content blocks" do
        response = {
          "jsonrpc" => "2.0", "id" => 1,
          "result" => {
            "content" => [{"type" => "text", "text" => "hello"}]
          }
        }
        allow(Open3).to receive(:capture3)
          .and_return([JSON.generate(response), "", double(success?: true, exitstatus: 0)])

        expect(transport.call_tool("search", {query: "hi"})).to eq("hello")
      end

      it "raises ToolError when the server exits with non-zero status" do
        allow(Open3).to receive(:capture3).and_return(["", "err", double(success?: false, exitstatus: 1)])
        expect { transport.call_tool("search", {}) }.to raise_error(Phronomy::ToolError, /MCP server/)
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
end
