#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal stdio MCP server for integration tests (official MCP Ruby SDK compatible).
# Processes JSON-RPC messages in a loop so that the official SDK's initialize
# handshake (initialize → notifications/initialized → tools/list → tools/call)
# is handled correctly.
#
# Tools exposed:
#   - "add"  (parameters: a: integer, b: integer)
#   - "echo" (parameters: message: string)
#
# Pass --empty to respond with an empty tools list.
# Pass --error to exit with status 1 immediately.
# Pass --multi to respond to tools/call with multiple content blocks.

require "json"

mode = ARGV[0]

if mode == "--error"
  warn "Simulated MCP server error"
  exit(1)
end

empty_tools = mode == "--empty"
multi_content = mode == "--multi"

TOOLS_LIST = empty_tools ? [] : [
  {
    "name" => "add",
    "description" => "Adds two integers and returns the sum",
    "inputSchema" => {
      "type" => "object",
      "properties" => {
        "a" => {"type" => "integer", "description" => "First integer"},
        "b" => {"type" => "integer", "description" => "Second integer"}
      }
    }
  },
  {
    "name" => "echo",
    "description" => "Returns the input message unchanged",
    "inputSchema" => {
      "type" => "object",
      "properties" => {
        "message" => {"type" => "string", "description" => "Message to echo back"}
      }
    }
  }
]

$stdout.sync = true

$stdin.each_line do |line|
  line = line.strip
  next if line.empty?

  request = JSON.parse(line)
  method = request["method"]
  req_id = request["id"]

  response = case method
  when "initialize"
    {
      "jsonrpc" => "2.0", "id" => req_id,
      "result" => {
        "protocolVersion" => "2025-03-26",
        "capabilities" => {"tools" => {"listChanged" => false}},
        "serverInfo" => {"name" => "test-mcp-server", "version" => "0.1.0"}
      }
    }
  when "notifications/initialized"
    next # notification: no response required
  when "tools/list"
    {"jsonrpc" => "2.0", "id" => req_id, "result" => {"tools" => TOOLS_LIST}}
  when "tools/call"
    args = request.dig("params", "arguments") || {}
    tool_name = request.dig("params", "name")
    result_text = case tool_name
    when "add"
      ((args["a"] || 0) + (args["b"] || 0)).to_s
    when "echo"
      args["message"].to_s
    else
      "unknown tool"
    end
    content = if multi_content
      [{"type" => "text", "text" => result_text}, {"type" => "text", "text" => "extra block"}]
    else
      [{"type" => "text", "text" => result_text}]
    end
    {"jsonrpc" => "2.0", "id" => req_id, "result" => {"content" => content}}
  else
    {"jsonrpc" => "2.0", "id" => req_id, "error" => {"code" => -32601, "message" => "Method not found"}}
  end

  $stdout.puts JSON.generate(response)
end
