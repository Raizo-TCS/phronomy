# frozen_string_literal: true

require "json"
require "open3"

module Phronomy
  module Tool
    # A Phronomy::Tool::Base subclass that wraps a tool exposed by an external
    # MCP (Model Context Protocol) server.
    #
    # Currently supports the **stdio** transport only: the MCP server is launched
    # as a child process and communicates via newline-delimited JSON-RPC on stdin/stdout.
    #
    # HTTP/SSE transport support can be added later by subclassing Transport.
    #
    # @example
    #   web_search = Phronomy::Tool::McpTool.from_server(
    #     "stdio://./mcp-server",
    #     tool_name: "search_web"
    #   )
    #   agent = MyAgent.new
    #   agent_class.tools(web_search)
    class McpTool < Base
      class << self
        # Build a McpTool instance by querying a running MCP server for the
        # tool definition identified by +tool_name+.
        #
        # @param server_uri [String] URI of the MCP server.
        #   Supported schemes:
        #   - "stdio://<command>"  — spawn a child process
        # @param tool_name [String] the tool name as registered in the MCP server
        # @return [McpTool] a configured subclass instance ready for use with an Agent
        def from_server(server_uri, tool_name:)
          transport = build_transport(server_uri)
          tool_def  = transport.fetch_tool(tool_name)
          build_tool_class(tool_name, tool_def, transport).new
        end

        private

        def build_transport(uri)
          scheme, path = uri.split("://", 2)
          case scheme
          when "stdio"
            StdioTransport.new(path)
          else
            raise ArgumentError, "Unsupported MCP transport scheme: #{scheme.inspect}. Only 'stdio://' is currently supported."
          end
        end

        def build_tool_class(tool_name, tool_def, transport)
          klass = Class.new(McpTool)
          klass.instance_variable_set(:@mcp_tool_name, tool_name)
          klass.instance_variable_set(:@mcp_transport, transport)

          # Register description and params from the MCP tool definition.
          klass.description(tool_def[:description] || tool_name)
          (tool_def[:parameters] || []).each do |p|
            klass.param(p[:name].to_sym, type: p[:type]&.to_sym || :string, desc: p[:description].to_s)
          end

          # Define #execute to forward the call to the MCP server.
          klass.define_method(:execute) do |**args|
            self.class.instance_variable_get(:@mcp_transport)
              .call_tool(tool_name, args)
          end

          klass
        end
      end

      # -----------------------------------------------------------------------
      # Transports
      # -----------------------------------------------------------------------

      # Minimal stdio transport implementing a subset of the MCP JSON-RPC protocol.
      # Spawns the server command as a child process and communicates line-by-line.
      class StdioTransport
        def initialize(command)
          @command = command
        end

        # Retrieve the tool definition from the server using the MCP `tools/list` method.
        # @param tool_name [String]
        # @return [Hash] { description:, parameters: }
        def fetch_tool(tool_name)
          response = rpc_call("tools/list", {})
          tools = response.dig("result", "tools") || []
          defn  = tools.find { |t| t["name"] == tool_name }
          raise ArgumentError, "Tool #{tool_name.inspect} not found on MCP server #{@command.inspect}" unless defn

          {
            description: defn["description"],
            parameters:  parse_schema_params(defn.dig("inputSchema", "properties") || {})
          }
        end

        # Call a tool on the MCP server using the `tools/call` method.
        # @param tool_name [String]
        # @param args [Hash]
        # @return [Object] the tool result
        def call_tool(tool_name, args)
          response = rpc_call("tools/call", {name: tool_name, arguments: args})
          content  = response.dig("result", "content")

          # MCP content is an array of content blocks; extract text blocks.
          if content.is_a?(Array)
            texts = content.select { |c| c["type"] == "text" }.map { |c| c["text"] }
            texts.length == 1 ? texts.first : texts
          else
            content
          end
        end

        private

        def rpc_call(method, params)
          payload = JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params)
          stdout, _stderr, status = Open3.capture3(@command, stdin_data: "#{payload}\n")
          raise Phronomy::ToolError, "MCP server exited with status #{status.exitstatus}" unless status.success?

          JSON.parse(stdout.lines.first.to_s)
        end

        def parse_schema_params(properties)
          properties.map do |name, schema|
            {
              name:        name.to_s,
              type:        schema["type"] || "string",
              description: schema["description"].to_s
            }
          end
        end
      end
    end
  end
end
