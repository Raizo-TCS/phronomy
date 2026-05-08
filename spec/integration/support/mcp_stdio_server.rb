#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal stdio MCP server for integration tests.
# Reads a single JSON-RPC request from stdin, responds on stdout, then exits.
#
# Tools exposed:
#   - "add"  (parameters: a: integer, b: integer)
#   - "echo" (parameters: message: string)
#
# Pass --empty to respond with an empty tools list (for tools_list_empty tests).
# Pass --error to exit with status 1 (for http_error/server-error tests).
# Pass --multi to respond to tools/call with multiple content blocks.

require "json"

mode = ARGV[0]

if mode == "--error"
  warn "Simulated MCP server error"
  exit(1)
end

empty_tools = mode == "--empty"
multi_content = mode == "--multi"

# Read one line (one JSON-RPC request) from stdin
line = $stdin.readline.strip
request = JSON.parse(line)
method = request["method"]
req_id = request["id"]

case method
when "tools/list"
  tools = empty_tools ? [] : [
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
  puts JSON.generate({"jsonrpc" => "2.0", "id" => req_id, "result" => {"tools" => tools}})

when "tools/call"
  args = request.dig("params", "arguments") || {}
  tool_name = request.dig("params", "name")

  result_text =
    case tool_name
    when "add"
      ((args["a"] || 0) + (args["b"] || 0)).to_s
    when "echo"
      args["message"].to_s
    else
      "unknown tool"
    end

  content =
    if multi_content
      [
        {"type" => "text", "text" => result_text},
        {"type" => "text", "text" => "extra block"}
      ]
    else
      [{"type" => "text", "text" => result_text}]
    end

  puts JSON.generate({"jsonrpc" => "2.0", "id" => req_id, "result" => {"content" => content}})

else
  puts JSON.generate({"jsonrpc" => "2.0", "id" => req_id, "error" => {"code" => -32601, "message" => "Method not found"}})
end
