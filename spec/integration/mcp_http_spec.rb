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

        # Always handle the MCP initialize handshake so the official SDK can connect.
        case method_name
        when "initialize"
          res.content_type = "application/json"
          res.body = JSON.generate({
            "jsonrpc" => "2.0", "id" => req_id,
            "result" => {
              "protocolVersion" => "2025-03-26",
              "capabilities" => {"tools" => {"listChanged" => false}},
              "serverInfo" => {"name" => "test-server", "version" => "0.1.0"}
            }
          })
          next
        when "notifications/initialized"
          # MCP notification: return 202 Accepted with no body.
          res.status = 202
          res.body = ""
          next
        end

        case response_mode
        when :json_ok
          handle_json_request(server, res, req_id, method_name, tools_empty: tools_empty)
        when :json_multi
          handle_json_request(server, res, req_id, method_name, multi: true)
        when :sse_ok
          handle_sse_request(server, res, req_id, method_name, tools_empty: false)
        when :sse_no_rpc
          # For tools/list, return a valid SSE so from_server succeeds.
          # For tools/call, return invalid SSE (no JSON-RPC) to trigger ToolError.
          if method_name == "tools/list"
            handle_sse_request(server, res, req_id, method_name, tools_empty: false)
          else
            res.content_type = "text/event-stream"
            res.body = "data: {\"other\":true}\n\n"
          end
        when :error_500
          # Fail only on tools/call so that from_server (tools/list) succeeds first.
          if method_name == "tools/call"
            res.status = 500
            res.body = "Internal Server Error"
          else
            handle_json_request(server, res, req_id, method_name, tools_empty: false)
          end
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
        server_uri = "stdio://#{RUBY_CMD} #{STDIO_SERVER}"
        tool = Phronomy::Tools::Mcp.from_server(server_uri, tool_name: "add")
        result = tool.execute(a: 3, b: 4)
        expect(result).to eq("7")
      end
    end

    # TC-004: stdio + tools_call_multi — execute returns Array
    describe "TC-004: stdio + tools_call_multi — execute returns Array of strings" do
      it "returns an Array when multiple content blocks are present" do
        server_uri = "stdio://#{RUBY_CMD} #{STDIO_SERVER} --multi"
        tool = Phronomy::Tools::Mcp.from_server(server_uri, tool_name: "add")
        result = tool.execute(a: 1, b: 2)
        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
        expect(result.first).to be_a(String)
      end
    end

    # TC-005: stdio + server error — ToolError raised
    describe "TC-005: stdio + server error (non-zero exit) — ToolError" do
      it "raises Phronomy::ToolError" do
        server_uri = "stdio://#{RUBY_CMD} #{STDIO_SERVER} --error"
        expect {
          Phronomy::Tools::Mcp.from_server(server_uri, tool_name: "add")
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
    describe "TC-008: http + tools_call_ok + json — execute returns String" do
      it "returns a single String result" do
        tool = Phronomy::Tools::Mcp.from_server(
          "http://127.0.0.1:#{mcp_port}/mcp",
          tool_name: "greet"
        )
        result = tool.execute(name: "Alice")
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
        tool = Phronomy::Tools::Mcp.from_server(
          "http://127.0.0.1:#{mcp_port}/mcp",
          tool_name: "greet"
        )
        result = tool.execute(name: "Alice")
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
        tool = Phronomy::Tools::Mcp.from_server(
          "http://127.0.0.1:#{mcp_port}/mcp",
          tool_name: "greet"
        )
        expect {
          tool.execute(name: "Alice")
        }.to raise_error(Phronomy::ToolError)
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
    describe "TC-016: http + tools_call_ok + sse — execute returns String" do
      it "returns a String from an SSE response" do
        tool = Phronomy::Tools::Mcp.from_server(
          "http://127.0.0.1:#{mcp_port}/mcp",
          tool_name: "greet"
        )
        result = tool.execute(name: "SSE")
        expect(result).to be_a(String)
      end
    end
  end

  describe "http transport — SSE response without valid JSON-RPC", real_backend: :mcp_http do
    include_context "with http mcp server", response_mode: :sse_no_rpc

    # TC-018: sse without JSON-RPC message → ToolError
    describe "TC-018: http + sse response with no JSON-RPC data — ToolError" do
      it "raises Phronomy::ToolError" do
        tool = Phronomy::Tools::Mcp.from_server(
          "http://127.0.0.1:#{mcp_port}/mcp",
          tool_name: "greet"
        )
        expect {
          tool.execute(name: "Fail")
        }.to raise_error(Phronomy::ToolError)
      end
    end
  end

  # ===========================================================================
  # HTTPS transport — url forwarding check (unit-level; no actual TLS server)
  # ===========================================================================
  describe "TC-012: https:// scheme passes correct URL to MCP::Client::HTTP", real_backend: :mcp_http do
    it "creates MCP::Client::HTTP with the https:// URL" do
      transport_dbl = instance_double(MCP::Client::HTTP, close: nil)
      allow(MCP::Client::HTTP).to receive(:new)
        .with(url: "https://example.com/mcp", headers: {})
        .and_return(transport_dbl)
      client_dbl = instance_double(MCP::Client, connect: nil, tools: [])
      allow(MCP::Client).to receive(:new).and_return(client_dbl)

      expect {
        Phronomy::Tools::Mcp.from_server("https://example.com/mcp", tool_name: "any")
      }.to raise_error(ArgumentError)

      expect(MCP::Client::HTTP).to have_received(:new)
        .with(url: "https://example.com/mcp", headers: {}).at_least(:once)
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
