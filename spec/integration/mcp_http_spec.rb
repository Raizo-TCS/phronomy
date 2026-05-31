# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require "webrick"
require "json"

# Group 11: MCP HTTP/SSE Transport
# Pairwise factors: mcp_transport_scheme × mcp_server_response × mcp_content_type
# Generated stubs: 25 cases
#
# Infeasible / N/A cases:
#   TC-001 to TC-005: stdio × mcp_content_type — content_type is irrelevant for stdio
#                     (stdio uses JSON-RPC over stdin/stdout, not HTTP Content-Type).
#                     Tested as stdio-only cases without content_type dimension.
#   TC-002: stdio + tools_list_empty + sse — sse content_type is N/A for stdio; tested as
#           tools_list_empty without content_type.
#   TC-012: https + tools_list_ok + json — TLS requires a valid certificate; tested as
#           unit-level check that HttpTransport sets use_ssl=true.
#
# Verified feasible cases:
#   stdio:   TC-001 (tools_list_ok), TC-002 (tools_list_empty → ArgumentError),
#            TC-003 (tools_call_ok), TC-004 (tools_call_multi), TC-005 (server error → ToolError)
#   http+json: TC-006 (tools_list_ok), TC-007 (tools_list_empty → ArgumentError),
#              TC-008 (tools_call_ok), TC-009 (tools_call_multi), TC-010 (500 → ToolError)
#   http+sse:  TC-011 (tools_list_ok via SSE), TC-016 (call_tool via SSE),
#              TC-018 (SSE without valid JSON-RPC → ToolError)
#   https:     TC-012 (use_ssl flag check — unit-level mock)
#   unsupported: TC-013 (ArgumentError)

STDIO_SERVER = File.expand_path("support/mcp_stdio_server.rb", __dir__)
RUBY_CMD = RbConfig.ruby

RSpec.describe "Group 11: MCP HTTP/SSE Transport", :integration do
  # ---------------------------------------------------------------------------
  # Shared WEBrick server setup (used by http:// test groups)
  # ---------------------------------------------------------------------------
  shared_context "with http mcp server" do |response_mode: :json_ok, tools_empty: false|
    let(:mcp_server) do
      server = WEBrick::HTTPServer.new(
        Port: 0,
        Logger: WEBrick::Log.new(IO::NULL, WEBrick::BasicLog::ERROR),
        AccessLog: []
      )

      server.mount_proc("/mcp") do |req, res|
        body = JSON.parse(req.body || "{}")
        method_name = body["method"]
        req_id = body["id"]

        case response_mode
        when :json_ok
          handle_json_request(server, res, req_id, method_name, tools_empty: tools_empty)
        when :json_multi
          handle_json_request(server, res, req_id, method_name, multi: true)
        when :sse_ok
          handle_sse_request(server, res, req_id, method_name, tools_empty: false)
        when :sse_no_rpc
          res.content_type = "text/event-stream"
          res.body = "data: {\"other\":true}\n\n"
        when :error_500
          res.status = 500
          res.body = "Internal Server Error"
        end
      end

      server
    end

    let(:mcp_port) do
      mcp_server.config[:Port]
    end

    around do |example|
      thread = Thread.new { mcp_server.start }
      # Wait until the port is actually open (max 2 seconds)
      deadline = Time.now + 2
      begin
        TCPSocket.new("127.0.0.1", mcp_port).close
      rescue Errno::ECONNREFUSED
        retry if Time.now < deadline
        raise "WEBrick did not start in time"
      end
      example.run
    ensure
      mcp_server.shutdown
      thread.join(2)
    end

    # Helpers used inside mount_proc (closures referencing local method-like blocks)
    def handle_json_request(_server, res, req_id, method_name, tools_empty: false, multi: false)
      res.content_type = "application/json"
      res.body = case method_name
      when "tools/list"
        tools = tools_empty ? [] : sample_tools
        JSON.generate({"jsonrpc" => "2.0", "id" => req_id, "result" => {"tools" => tools}})
      when "tools/call"
        content = multi ? multi_content_blocks : single_content_block
        JSON.generate({"jsonrpc" => "2.0", "id" => req_id, "result" => {"content" => content}})
      else
        JSON.generate({"jsonrpc" => "2.0", "id" => req_id,
                       "error" => {"code" => -32_601, "message" => "Method not found"}})
      end
    end

    def handle_sse_request(_server, res, req_id, method_name, tools_empty: false)
      res.content_type = "text/event-stream"
      rpc_result = case method_name
      when "tools/list"
        tools = tools_empty ? [] : sample_tools
        {"jsonrpc" => "2.0", "id" => req_id, "result" => {"tools" => tools}}
      when "tools/call"
        {"jsonrpc" => "2.0", "id" => req_id, "result" => {"content" => single_content_block}}
      end
      res.body = "data: #{JSON.generate(rpc_result)}\n\n"
    end

    def sample_tools
      [{
        "name" => "greet",
        "description" => "Returns a greeting",
        "inputSchema" => {
          "type" => "object",
          "properties" => {"name" => {"type" => "string", "description" => "Name to greet"}}
        }
      }]
    end

    def single_content_block
      [{"type" => "text", "text" => "Hello, World!"}]
    end

    def multi_content_blocks
      [
        {"type" => "text", "text" => "First result"},
        {"type" => "text", "text" => "Second result"}
      ]
    end
  end

  # ===========================================================================
  # STDIO transport tests
  # ===========================================================================
  describe "stdio transport", real_backend: :mcp_stdio do
    # TC-001: stdio + tools_list_ok — from_server returns a McpTool instance
    describe "TC-001: stdio + tools_list_ok — from_server succeeds" do
      it "builds a McpTool with description and params from server" do
        server_uri = "stdio://#{RUBY_CMD} #{STDIO_SERVER}"
        tool = Phronomy::Tools::Mcp.from_server(server_uri, tool_name: "add")
        expect(tool).to be_a(Phronomy::Tools::Mcp)
        expect(tool.class.description).to eq("Adds two integers and returns the sum")
      end
    end

    # TC-002: stdio + tools_list_empty — from_server raises ArgumentError
    describe "TC-002: stdio + tools_list_empty — ArgumentError when tool not found" do
      it "raises ArgumentError" do
        server_uri = "stdio://#{RUBY_CMD} #{STDIO_SERVER} --empty"
        expect {
          Phronomy::Tools::Mcp.from_server(server_uri, tool_name: "add")
        }.to raise_error(ArgumentError, /not found/)
      end
    end

    # TC-003: stdio + tools_call_ok — execute returns single text result
    describe "TC-003: stdio + tools_call_ok — execute returns single String" do
      it "returns the sum as a string" do
        # We need a fresh from_server for each call because StdioTransport runs the
        # server command on every rpc_call (Open3.capture3). However, fetch_tool
        # and call_tool each spawn a separate process. We verify call_tool here by
        # calling the transport directly.
        transport = Phronomy::Tools::Mcp::StdioTransport.new("#{RUBY_CMD} #{STDIO_SERVER}")
        result = transport.call_tool("add", {"a" => 3, "b" => 4})
        expect(result).to eq("7")
      end
    end

    # TC-004: stdio + tools_call_multi — execute returns Array
    describe "TC-004: stdio + tools_call_multi — execute returns Array of strings" do
      it "returns an Array when multiple content blocks are present" do
        transport = Phronomy::Tools::Mcp::StdioTransport.new(
          "#{RUBY_CMD} #{STDIO_SERVER} --multi"
        )
        result = transport.call_tool("add", {"a" => 1, "b" => 2})
        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
        expect(result.first).to be_a(String)
      end
    end

    # TC-005: stdio + server error — ToolError raised
    describe "TC-005: stdio + server error (non-zero exit) — ToolError" do
      it "raises Phronomy::ToolError" do
        transport = Phronomy::Tools::Mcp::StdioTransport.new(
          "#{RUBY_CMD} #{STDIO_SERVER} --error"
        )
        expect {
          transport.call_tool("add", {"a" => 1, "b" => 2})
        }.to raise_error(Phronomy::ToolError)
      end
    end
  end

  # ===========================================================================
  # HTTP transport — JSON responses
  # ===========================================================================
  describe "http transport — JSON responses", real_backend: :mcp_http do
    include_context "with http mcp server", response_mode: :json_ok

    # TC-006: http + tools_list_ok + json — from_server returns McpTool
    describe "TC-006: http + tools_list_ok + json — from_server succeeds" do
      it "builds a McpTool instance" do
        tool = Phronomy::Tools::Mcp.from_server(
          "http://127.0.0.1:#{mcp_port}/mcp",
          tool_name: "greet"
        )
        expect(tool).to be_a(Phronomy::Tools::Mcp)
        expect(tool.class.description).to eq("Returns a greeting")
      end
    end

    # TC-008: http + tools_call_ok + json — call returns single text String
    describe "TC-008: http + tools_call_ok + json — HttpTransport#call_tool returns String" do
      it "returns a single String result" do
        transport = Phronomy::Tools::Mcp::HttpTransport.new(
          "http://127.0.0.1:#{mcp_port}/mcp"
        )
        result = transport.call_tool("greet", {"name" => "Alice"})
        expect(result).to be_a(String)
        expect(result).not_to be_empty
      end
    end
  end

  describe "http transport — JSON responses (empty tools list)", real_backend: :mcp_http do
    include_context "with http mcp server", response_mode: :json_ok, tools_empty: true

    # TC-007: http + tools_list_empty + json — ArgumentError
    describe "TC-007: http + tools_list_empty + json — ArgumentError" do
      it "raises ArgumentError when tool is not in server list" do
        expect {
          Phronomy::Tools::Mcp.from_server(
            "http://127.0.0.1:#{mcp_port}/mcp",
            tool_name: "greet"
          )
        }.to raise_error(ArgumentError, /not found/)
      end
    end
  end

  describe "http transport — JSON multi-content response", real_backend: :mcp_http do
    include_context "with http mcp server", response_mode: :json_multi

    # TC-009: http + tools_call_multi + json — Array returned
    describe "TC-009: http + tools_call_multi + json — returns Array" do
      it "returns an Array of Strings" do
        transport = Phronomy::Tools::Mcp::HttpTransport.new(
          "http://127.0.0.1:#{mcp_port}/mcp"
        )
        result = transport.call_tool("greet", {"name" => "Alice"})
        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
      end
    end
  end

  describe "http transport — 500 error response", real_backend: :mcp_http do
    include_context "with http mcp server", response_mode: :error_500

    # TC-010: http + http_error (500) + json — ToolError raised
    describe "TC-010: http + 500 response — Phronomy::ToolError" do
      it "raises Phronomy::ToolError with status code in message" do
        transport = Phronomy::Tools::Mcp::HttpTransport.new(
          "http://127.0.0.1:#{mcp_port}/mcp"
        )
        expect {
          transport.call_tool("greet", {"name" => "Alice"})
        }.to raise_error(Phronomy::ToolError, /500/)
      end
    end
  end

  # ===========================================================================
  # HTTP transport — SSE responses
  # ===========================================================================
  describe "http transport — SSE responses", real_backend: :mcp_http do
    include_context "with http mcp server", response_mode: :sse_ok

    # TC-011: http + tools_list_ok + sse — from_server parses SSE JSON-RPC
    describe "TC-011: http + tools_list_ok + sse — from_server parses SSE response" do
      it "builds a McpTool from an SSE response" do
        tool = Phronomy::Tools::Mcp.from_server(
          "http://127.0.0.1:#{mcp_port}/mcp",
          tool_name: "greet"
        )
        expect(tool).to be_a(Phronomy::Tools::Mcp)
      end
    end

    # TC-016: http + tools_call_ok + sse — call_tool parses SSE JSON-RPC
    describe "TC-016: http + tools_call_ok + sse — HttpTransport#call_tool returns String" do
      it "returns a String from an SSE response" do
        transport = Phronomy::Tools::Mcp::HttpTransport.new(
          "http://127.0.0.1:#{mcp_port}/mcp"
        )
        result = transport.call_tool("greet", {"name" => "SSE"})
        expect(result).to be_a(String)
      end
    end
  end

  describe "http transport — SSE response without valid JSON-RPC", real_backend: :mcp_http do
    include_context "with http mcp server", response_mode: :sse_no_rpc

    # TC-018: sse without JSON-RPC message → ToolError
    describe "TC-018: http + sse response with no JSON-RPC data — ToolError" do
      it "raises Phronomy::ToolError" do
        transport = Phronomy::Tools::Mcp::HttpTransport.new(
          "http://127.0.0.1:#{mcp_port}/mcp"
        )
        expect {
          transport.call_tool("greet", {"name" => "Fail"})
        }.to raise_error(Phronomy::ToolError, /No valid JSON-RPC/)
      end
    end
  end

  # ===========================================================================
  # HTTPS transport — use_ssl flag (unit-level check; no actual TLS server)
  # ===========================================================================
  describe "TC-012: https:// scheme sets use_ssl=true on Net::HTTP", real_backend: :mcp_http do
    it "configures Net::HTTP to use SSL" do
      transport = Phronomy::Tools::Mcp::HttpTransport.new("https://example.com/mcp")
      allow(Net::HTTP).to receive(:new).and_call_original

      http_double = instance_double(Net::HTTP, "use_ssl=": nil, "open_timeout=": nil, "read_timeout=": nil, request: nil)
      allow(Net::HTTP).to receive(:new).with("example.com", 443).and_return(http_double)
      allow(http_double).to receive(:use_ssl=).with(true)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)

      # We expect a SocketError or connection error since example.com isn't running an MCP server;
      # the important assertion is that use_ssl= was called with true.
      http_double_response = instance_double(Net::HTTPOK)
      allow(http_double_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(http_double_response).to receive(:[]).with("Content-Type").and_return("application/json")
      allow(http_double_response).to receive(:body).and_return(
        JSON.generate("jsonrpc" => "2.0", "id" => 1,
          "result" => {"tools" => []})
      )
      allow(http_double).to receive(:request).and_return(http_double_response)

      expect(http_double).to receive(:use_ssl=).with(true)
      begin
        transport.fetch_tool("any_tool")
      rescue
        nil
      end
    end
  end

  # ===========================================================================
  # Unsupported scheme
  # ===========================================================================
  # TC-013: unsupported scheme → ArgumentError
  describe "TC-013: unsupported transport scheme — ArgumentError", real_backend: :mcp_http do
    it "raises ArgumentError for an unknown scheme" do
      expect {
        Phronomy::Tools::Mcp.from_server("grpc://localhost:50051", tool_name: "greet")
      }.to raise_error(ArgumentError, /Unsupported MCP transport scheme/)
    end
  end
end
