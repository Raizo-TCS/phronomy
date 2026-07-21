# frozen_string_literal: true

require "mcp"
require "shellwords"
require "uri"

module Phronomy
  module Tools
    # A Phronomy::Agent::Context::Capability::Base subclass that wraps a tool exposed by an external
    # MCP (Model Context Protocol) server.
    #
    # Uses the official MCP Ruby SDK (mcp gem) for transport handling, which provides
    # built-in support for the MCP initialize handshake, size limits, and SSE.
    #
    # Supports two transport schemes:
    # - <b>"stdio://\<command\>"</b> — spawns a child process via MCP::Client::Stdio.
    # - <b>"http://\<url\>"</b> / <b>"https://\<url\>"</b> — connects via MCP::Client::HTTP.
    #
    # @example
    #   web_search = Phronomy::Tools::Mcp.from_server(
    #     "stdio://./mcp-server",
    #     tool_name: "search_web"
    #   )
    #   agent = MyAgent.new
    #   agent_class.tools(web_search)
    class Mcp < Phronomy::Agent::Context::Capability::Base
      class << self
        # Build a Mcp instance by querying a running MCP server for the
        # tool definition identified by +tool_name+.
        #
        # @param server_uri [String] URI of the MCP server.
        #   Supported schemes:
        #   - "stdio://<command>"  — spawn a child process
        #   - "http://<url>" / "https://<url>" — connect to an HTTP/SSE server
        # @param tool_name [String] the tool name as registered in the MCP server
        # @param headers [Hash] additional HTTP request headers forwarded to every
        #   request (tool discovery and tool execution). Ignored for stdio transports.
        #   Typical use: <tt>headers: { "Authorization" => "Bearer #{ENV['API_KEY']}" }</tt>
        # @return [Mcp] a configured subclass instance ready for use with an Agent
        # @api public
        def from_server(server_uri, tool_name:, headers: {})
          # Use a short-lived client only to discover the tool definition, then close.
          # Each Mcp instance creates its own client so concurrent agent threads
          # never share IO streams, eliminating the need for synchronisation.
          transport = build_transport(server_uri, headers: headers)
          client = MCP::Client.new(transport: transport)
          begin
            client.connect
            tool_def = extract_tool_def(client, tool_name.to_s, server_uri)
          rescue ArgumentError
            raise
          rescue => e
            raise Phronomy::ToolError, "MCP connection failed: #{e.message}"
          ensure
            transport.close
          end
          build_tool_class(tool_name, server_uri, tool_def, headers: headers).new
        end

        private

        def build_transport(uri, headers: {})
          scheme, path = uri.split("://", 2)
          case scheme
          when "stdio"
            argv = Shellwords.split(path)
            MCP::Client::Stdio.new(command: argv[0], args: argv[1..])
          when "http", "https"
            MCP::Client::HTTP.new(url: uri, headers: headers)
          else
            raise ArgumentError, "Unsupported MCP transport scheme: #{scheme.inspect}. Supported: 'stdio://', 'http://', 'https://'."
          end
        end

        def extract_tool_def(client, tool_name, server_uri)
          mcp_tool = client.tools.find { |t| t.name == tool_name }
          raise ArgumentError, "Tool #{tool_name.inspect} not found on MCP server #{server_uri.inspect}" unless mcp_tool

          properties = mcp_tool.input_schema&.dig("properties") || {}
          required_names = mcp_tool.input_schema&.dig("required") || []
          {
            description: mcp_tool.description || tool_name,
            parameters: parse_schema_params(properties, required_names: required_names)
          }
        end

        def build_tool_class(tool_name, server_uri, tool_def, headers: {})
          klass = Class.new(Mcp)
          klass.tool_name(tool_name)
          klass.instance_variable_set(:@mcp_server_uri, server_uri)
          klass.instance_variable_set(:@mcp_headers, headers)

          # Register description and params from the MCP tool definition.
          klass.description(tool_def[:description] || tool_name)
          (tool_def[:parameters] || []).each do |p|
            opts = {type: p[:type]&.to_sym || :string, desc: p[:description].to_s}
            opts[:required] = p[:required] if p.key?(:required)
            opts[:enum] = p[:enum] if p.key?(:enum)
            klass.param(p[:name].to_sym, **opts)
          end

          # Each instance creates its own MCP client so concurrent agent threads
          # never share IO streams.
          klass.define_method(:initialize) do
            uri = self.class.instance_variable_get(:@mcp_server_uri)
            hdrs = self.class.instance_variable_get(:@mcp_headers) || {}
            transport = self.class.send(:build_transport, uri, headers: hdrs)
            @mcp_client = MCP::Client.new(transport: transport)
            @mcp_client.connect
          end

          klass.define_method(:execute) do |**args|
            begin
              response = @mcp_client.call_tool(name: tool_name, arguments: args.transform_keys(&:to_s))
            rescue => e
              raise Phronomy::ToolError, "MCP call failed: #{e.message}"
            end
            if response["error"]
              err_msg = response.dig("error", "message") || response["error"].to_s
              raise Phronomy::ToolError, "MCP server returned error: #{err_msg}"
            end
            content = response.dig("result", "content")
            if content.is_a?(Array)
              texts = content.select { |c| c["type"] == "text" }.map { |c| c["text"] }
              (texts.length == 1) ? texts.first : texts
            else
              content
            end
          end

          # Allow callers to deterministically shut down the underlying transport.
          klass.define_method(:close) do
            @mcp_client.transport.close
          end

          klass
        end

        def parse_schema_params(properties, required_names: [])
          properties.map do |name, schema|
            param = {
              name: name.to_s,
              type: schema["type"] || "string",
              description: schema["description"].to_s,
              required: required_names.include?(name.to_s)
            }
            param[:enum] = schema["enum"] if schema["enum"]
            param
          end
        end
      end
    end
  end
end
