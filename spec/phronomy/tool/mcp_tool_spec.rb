# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tool::McpTool do
  it "is a subclass of Phronomy::Tool::Base" do
    expect(described_class).to be < Phronomy::Tool::Base
  end

  describe ".from_server" do
    it "raises ArgumentError for unsupported transport schemes" do
      expect {
        described_class.from_server("http://localhost:9000", tool_name: "search")
      }.to raise_error(ArgumentError, /http/)
    end

    context "with a mocked stdio transport" do
      let(:transport_double) do
        instance_double(Phronomy::Tool::McpTool::StdioTransport).tap do |t|
          allow(t).to receive(:fetch_tool).with("search_web").and_return(
            description: "Search the web",
            parameters:  [
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
          "result"  => {
            "tools" => [{
              "name"        => "search",
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
          "result"  => {
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
end
