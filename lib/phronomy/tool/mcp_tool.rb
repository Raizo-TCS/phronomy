# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "securerandom"
require "shellwords"
require "uri"

module Phronomy
  module Tool
    # A Phronomy::Tool::Base subclass that wraps a tool exposed by an external
    # MCP (Model Context Protocol) server.
    #
    # Supports two transport schemes:
    # - <b>"stdio://\<command\>"</b> — spawns a child process that communicates via
    #   newline-delimited JSON-RPC on stdin/stdout.
    # - <b>"http://\<url\>"</b> / <b>"https://\<url\>"</b> — connects to a running
    #   HTTP/SSE MCP server using +net/http+.
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
        #   - "http://<url>" / "https://<url>" — connect to an HTTP/SSE server
        # @param tool_name [String] the tool name as registered in the MCP server
        # @return [McpTool] a configured subclass instance ready for use with an Agent
        def from_server(server_uri, tool_name:)
          # Use a short-lived transport only to query the tool definition,
          # then close it.  Each McpTool instance creates its own transport
          # so that concurrent callers never share IO streams.
          transport = build_transport(server_uri)
          tool_def = transport.fetch_tool(tool_name)
          transport.close
          build_tool_class(tool_name, server_uri, tool_def).new
        end

        private

        def build_transport(uri)
          scheme, path = uri.split("://", 2)
          case scheme
          when "stdio"
            StdioTransport.new(path)
          when "http", "https"
            HttpTransport.new(uri)
          else
            raise ArgumentError, "Unsupported MCP transport scheme: #{scheme.inspect}. Supported: 'stdio://', 'http://', 'https://'."
          end
        end

        def build_tool_class(tool_name, server_uri, tool_def)
          klass = Class.new(McpTool)
          klass.instance_variable_set(:@mcp_tool_name, tool_name)
          klass.instance_variable_set(:@mcp_server_uri, server_uri)

          # Register description and params from the MCP tool definition.
          klass.description(tool_def[:description] || tool_name)
          (tool_def[:parameters] || []).each do |p|
            klass.param(p[:name].to_sym, type: p[:type]&.to_sym || :string, desc: p[:description].to_s)
          end

          # Each instance creates its own transport so concurrent agent threads
          # never share IO streams, eliminating the need for synchronisation.
          klass.define_method(:initialize) do
            uri = self.class.instance_variable_get(:@mcp_server_uri)
            @mcp_transport = self.class.send(:build_transport, uri)
          end

          klass.define_method(:execute) do |**args|
            @mcp_transport.call_tool(tool_name, args)
          end

          # Allow callers to deterministically shut down the underlying child
          # process (stdio) or release the HTTP connection.  For HttpTransport
          # this is a no-op.  Calling execute after close raises an error.
          klass.define_method(:close) do
            @mcp_transport.close
          end

          klass
        end
      end

      # -----------------------------------------------------------------------
      # Transports
      # -----------------------------------------------------------------------

      # Minimal stdio transport implementing a subset of the MCP JSON-RPC protocol.
      # Keeps the child process alive for the lifetime of this transport instance
      # so that session state (registered resources, tool context, etc.) is preserved
      # across multiple calls.
      class StdioTransport
        def initialize(command)
          # Split the command string into an argv array so that Open3 executes
          # it directly without going through the shell, preventing injection.
          @command = Shellwords.split(command)
          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thr = nil
          @stderr_thread = nil
        end

        # Shut down the child process and close its IO streams.
        def close
          @stdin&.close
          @stdout&.close
          @stderr&.close
          @stdin = nil
          @stdout = nil
          @stderr = nil
          stderr_thread = @stderr_thread
          wait_thr = @wait_thr
          @stderr_thread = nil
          @wait_thr = nil
          stderr_thread&.join(1)
          wait_thr&.join(5)
        end

        # Retrieve the tool definition from the server using the MCP `tools/list` method.
        # @param tool_name [String]
        # @return [Hash] { description:, parameters: }
        def fetch_tool(tool_name)
          response = rpc_call("tools/list", {})
          tools = response.dig("result", "tools") || []
          defn = tools.find { |t| t["name"] == tool_name }
          raise ArgumentError, "Tool #{tool_name.inspect} not found on MCP server #{@command.inspect}" unless defn

          {
            description: defn["description"],
            parameters: parse_schema_params(defn.dig("inputSchema", "properties") || {})
          }
        end

        # Call a tool on the MCP server using the `tools/call` method.
        # @param tool_name [String]
        # @param args [Hash]
        # @return [Object] the tool result
        def call_tool(tool_name, args)
          response = rpc_call("tools/call", {name: tool_name, arguments: args})
          if response["error"]
            err_msg = response.dig("error", "message") || response["error"].to_s
            raise Phronomy::ToolError, "MCP server returned error: #{err_msg}"
          end
          content = response.dig("result", "content")

          # MCP content is an array of content blocks; extract text blocks.
          if content.is_a?(Array)
            texts = content.select { |c| c["type"] == "text" }.map { |c| c["text"] }
            (texts.length == 1) ? texts.first : texts
          else
            content
          end
        end

        private

        # Ensure the child process is running, spawning it if necessary.
        def ensure_started!
          return if @stdin && !@stdin.closed?

          @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(*@command)
          # Drain stderr asynchronously to prevent the pipe buffer from filling
          # and deadlocking the child process. Errors inside the drain thread are
          # silently ignored since stderr content is diagnostics-only.
          @stderr_thread = Thread.new do
            @stderr.read
          rescue
            nil
          end
        end

        def rpc_call(method, params)
          ensure_started!
          payload = JSON.generate(jsonrpc: "2.0", id: SecureRandom.uuid, method: method, params: params)
          @stdin.puts(payload)
          raw = @stdout.gets
          raise Phronomy::ToolError, "MCP server closed the connection unexpectedly" if raw.nil?
          JSON.parse(raw)
        end

        def parse_schema_params(properties)
          properties.map do |name, schema|
            {
              name: name.to_s,
              type: schema["type"] || "string",
              description: schema["description"].to_s
            }
          end
        end
      end

      # HTTP/HTTPS transport implementing JSON-RPC over HTTP with SSE support.
      #
      # Sends JSON-RPC POST requests to the MCP server endpoint.
      # Accepts both plain JSON responses (Content-Type: application/json) and
      # Server-Sent Events streams (Content-Type: text/event-stream), covering
      # both the 2024-11-05 and 2025-03-26 MCP HTTP transport specifications.
      #
      # @example
      #   tool = Phronomy::Tool::McpTool.from_server(
      #     "http://localhost:8080/mcp",
      #     tool_name: "weather_lookup"
      #   )
      class HttpTransport
        # @param base_url     [String]  full URL of the MCP endpoint, e.g. "http://localhost:8080/mcp"
        # @param open_timeout [Integer] TCP connection timeout in seconds (default: 5)
        # @param read_timeout [Integer] HTTP read timeout in seconds (default: 30)
        def initialize(base_url, open_timeout: 5, read_timeout: 30)
          @uri = URI.parse(base_url)
          @open_timeout = open_timeout
          @read_timeout = read_timeout
        end

        # HTTP connections are stateless; close is a no-op, defined so that
        # both transport classes share the same interface as StdioTransport.
        def close
        end

        # Retrieve the tool definition from the server using MCP `tools/list`.
        # @param tool_name [String]
        # @return [Hash] { description:, parameters: }
        def fetch_tool(tool_name)
          response = rpc_call("tools/list", {})
          tools = response.dig("result", "tools") || []
          defn = tools.find { |t| t["name"] == tool_name }
          raise ArgumentError, "Tool #{tool_name.inspect} not found on MCP server #{@uri}" unless defn

          {
            description: defn["description"],
            parameters: parse_schema_params(defn.dig("inputSchema", "properties") || {})
          }
        end

        # Call a tool on the MCP server using MCP `tools/call`.
        # @param tool_name [String]
        # @param args [Hash]
        # @return [Object] the tool result
        def call_tool(tool_name, args)
          response = rpc_call("tools/call", {name: tool_name, arguments: args})
          if response["error"]
            err_msg = response.dig("error", "message") || response["error"].to_s
            raise Phronomy::ToolError, "MCP HTTP server returned error: #{err_msg}"
          end
          content = response.dig("result", "content")

          if content.is_a?(Array)
            texts = content.select { |c| c["type"] == "text" }.map { |c| c["text"] }
            (texts.length == 1) ? texts.first : texts
          else
            content
          end
        end

        private

        def rpc_call(method, params)
          payload = JSON.generate(jsonrpc: "2.0", id: SecureRandom.uuid, method: method, params: params)

          http = Net::HTTP.new(@uri.host, @uri.port)
          http.use_ssl = (@uri.scheme == "https")
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout

          path = @uri.path.empty? ? "/" : @uri.path
          path = "#{path}?#{@uri.query}" if @uri.query

          request = Net::HTTP::Post.new(path)
          request["Content-Type"] = "application/json"
          request["Accept"] = "application/json, text/event-stream"
          request.body = payload

          http_response = http.request(request)

          unless http_response.is_a?(Net::HTTPSuccess)
            raise Phronomy::ToolError,
              "MCP HTTP server returned #{http_response.code}: #{http_response.body}"
          end

          content_type = http_response["Content-Type"] || ""
          if content_type.include?("text/event-stream")
            parse_sse_response(http_response.body)
          else
            JSON.parse(http_response.body)
          end
        end

        # Parse an SSE response body and extract the last JSON-RPC message.
        # SSE lines are in the format "data: <json>".
        def parse_sse_response(body)
          result = nil
          body.each_line do |line|
            line = line.strip
            next unless line.start_with?("data: ")

            data = line.delete_prefix("data: ")
            next if data == "[DONE]"

            begin
              parsed = JSON.parse(data)
              result = parsed if parsed.is_a?(Hash) && parsed["jsonrpc"]
            rescue JSON::ParserError
              next
            end
          end
          result || raise(Phronomy::ToolError, "No valid JSON-RPC response found in SSE stream")
        end

        def parse_schema_params(properties)
          properties.map do |name, schema|
            {
              name: name.to_s,
              type: schema["type"] || "string",
              description: schema["description"].to_s
            }
          end
        end
      end
    end
  end
end
