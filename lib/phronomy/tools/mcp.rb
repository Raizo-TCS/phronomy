# frozen_string_literal: true

require "json"
require "mcp"
require "shellwords"
require "uri"

module Phronomy
  module Tools
    # A Phronomy::Agent::Context::Capability::Base subclass that wraps a tool exposed by an external
    # MCP (Model Context Protocol) server.
    #
    # Uses the official MCP Ruby SDK v1.x for transport handling, which provides
    # the MCP initialize handshake, HTTP/SSE parsing, and request cancellation.
    #
    # Supports two transport schemes:
    # - <b>"stdio://\<command\>"</b> — spawns a child process via MCP::Client::Stdio.
    # - <b>"http://\<url\>"</b> / <b>"https://\<url\>"</b> — connects via MCP::Client::HTTP.
    #
    # Each generated tool instance owns one MCP client. Calls, reconnects, and
    # explicit close operations are serialized because the SDK's stdio transport
    # does not support concurrent response readers.
    #
    # @example
    #   web_search = Phronomy::Tools::Mcp.from_server(
    #     "stdio://./mcp-server",
    #     tool_name: "search_web"
    #   )
    #   agent_class.tools(web_search)
    class Mcp < Phronomy::Agent::Context::Capability::Base
      SUPPORTED_SCHEMA_DIALECTS = [
        "https://json-schema.org/draft/2020-12/schema",
        "https://json-schema.org/draft/2020-12/schema#"
      ].freeze
      SUPPORTED_ROOT_KEYS = %w[$schema type properties required title description additionalProperties].freeze
      SUPPORTED_PROPERTY_KEYS = %w[type description enum title].freeze
      IGNORED_PROPERTY_KEYS = %w[
        minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
        minLength maxLength pattern format default examples
      ].freeze
      SUPPORTED_TYPES = %w[string integer number boolean].freeze
      MCP_CLEANUP_POOL_SIZE = 2
      MCP_CLEANUP_QUEUE_SIZE = 100

      private_constant :SUPPORTED_SCHEMA_DIALECTS,
        :SUPPORTED_ROOT_KEYS,
        :SUPPORTED_PROPERTY_KEYS,
        :IGNORED_PROPERTY_KEYS,
        :SUPPORTED_TYPES,
        :MCP_CLEANUP_POOL_SIZE,
        :MCP_CLEANUP_QUEUE_SIZE

      class << self
        # Build a Mcp instance by querying a running MCP server for the
        # tool definition identified by +tool_name+.
        #
        # +additionalProperties+ omitted from the remote schema is accepted, but
        # Phronomy still exposes and accepts only parameters declared in +properties+.
        #
        # @param server_uri [String] URI of the MCP server.
        # @param tool_name [String] the tool name as registered in the MCP server
        # @param headers [Hash] additional HTTP headers forwarded to discovery and execution
        # @return [Mcp] configured tool instance
        # @api public
        def from_server(server_uri, tool_name:, headers: {})
          transport = nil
          begin
            transport = build_transport(server_uri, headers: headers)
            client = MCP::Client.new(transport: transport)
            client.connect
            tool_def = extract_tool_def(client, tool_name.to_s, server_uri)
          rescue ArgumentError, Phronomy::ToolError
            raise
          rescue => e
            raise Phronomy::ToolError, "MCP connection failed: #{e.message}"
          ensure
            close_transport_safely(transport)
          end

          build_tool_class(tool_name, server_uri, tool_def, headers: headers).new
        end

        private

        def build_transport(uri, headers: {})
          scheme, path = uri.split("://", 2)
          case scheme
          when "stdio"
            argv = Shellwords.split(path.to_s)
            if argv.empty? || argv[0].to_s.empty?
              raise ArgumentError, "MCP stdio URI must include a command"
            end

            MCP::Client::Stdio.new(command: argv[0], args: argv[1..])
          when "http", "https"
            MCP::Client::HTTP.new(url: uri, headers: headers)
          else
            raise ArgumentError,
              "Unsupported MCP transport scheme: #{scheme.inspect}. " \
              "Supported: 'stdio://', 'http://', 'https://'."
          end
        end

        def extract_tool_def(client, tool_name, server_uri)
          mcp_tool = client.tools.find { |tool| tool.name == tool_name }
          unless mcp_tool
            raise ArgumentError,
              "Tool #{tool_name.inspect} not found on MCP server #{server_uri.inspect}"
          end

          validate_supported_schema!(
            mcp_tool.input_schema,
            output_schema: mcp_tool.output_schema,
            tool_name: mcp_tool.name
          )

          input_schema = mcp_tool.input_schema
          properties = input_schema.fetch("properties", {})
          required_names = input_schema.fetch("required", [])

          {
            description: mcp_tool.description || tool_name,
            parameters: parse_schema_params(properties, required_names: required_names)
          }
        end

        def build_tool_class(tool_name, server_uri, tool_def, headers: {})
          klass = Class.new(Mcp)
          klass.tool_name(tool_name)
          klass.instance_variable_set(:@mcp_server_uri, server_uri)
          klass.instance_variable_set(:@mcp_headers, headers.dup.freeze)

          klass.description(tool_def[:description] || tool_name)
          (tool_def[:parameters] || []).each do |parameter|
            options = {
              type: parameter.fetch(:type).to_sym,
              desc: parameter[:description].to_s,
              required: parameter.fetch(:required, false)
            }
            options[:enum] = parameter[:enum] if parameter.key?(:enum)
            klass.param(parameter.fetch(:name).to_sym, **options)
          end

          klass
        end

        def parse_schema_params(properties, required_names: [])
          properties.map do |name, schema|
            parameter = {
              name: name.to_s,
              type: schema.fetch("type"),
              description: schema["description"].to_s,
              required: required_names.include?(name.to_s)
            }
            parameter[:enum] = schema["enum"] if schema.key?("enum")
            parameter
          end
        end

        def validate_supported_schema!(input_schema, output_schema:, tool_name:)
          unless input_schema.is_a?(Hash) && input_schema["type"] == "object"
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} must use an object input schema"
          end

          dialect = input_schema["$schema"]
          if dialect && !SUPPORTED_SCHEMA_DIALECTS.include?(dialect)
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} uses unsupported JSON Schema dialect #{dialect.inspect}"
          end

          unknown_root = input_schema.keys - SUPPORTED_ROOT_KEYS
          if unknown_root.any?
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} uses unsupported root schema keywords: " \
              "#{unknown_root.join(", ")}"
          end

          additional_properties = input_schema["additionalProperties"]
          unless additional_properties.nil? || additional_properties == false
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} uses additionalProperties: " \
              "#{additional_properties.inspect} (only false or omission is supported)"
          end

          properties = input_schema["properties"] || {}
          unless properties.is_a?(Hash)
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} has an invalid properties schema"
          end

          required_names = input_schema["required"] || []
          unless required_names.is_a?(Array) && required_names.all? { |name| name.is_a?(String) }
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} has an invalid required list"
          end

          unknown_required = required_names - properties.keys
          if unknown_required.any?
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} requires undefined parameters: " \
              "#{unknown_required.inspect}"
          end

          properties.each do |name, schema|
            validate_property_schema!(tool_name, name, schema)
          end

          if output_schema
            warn_mcp(
              "[Phronomy] MCP tool '#{tool_name}' has an output schema; " \
              "Phronomy does not yet use it for validation"
            )
          end
        end

        def validate_property_schema!(tool_name, name, schema)
          unless name.is_a?(String)
            raise Phronomy::ToolError,
              "MCP tool #{tool_name.inspect} has a non-string property key: #{name.inspect}"
          end
          unless schema.is_a?(Hash)
            raise Phronomy::ToolError,
              "MCP parameter #{name.inspect} must have an object schema"
          end

          type = schema["type"]
          unless type.is_a?(String) && SUPPORTED_TYPES.include?(type)
            raise Phronomy::ToolError,
              "MCP parameter #{name.inspect} uses unsupported type #{type.inspect}"
          end

          if schema.key?("enum")
            enum = schema["enum"]
            unless enum.is_a?(Array)
              raise Phronomy::ToolError,
                "MCP parameter #{name.inspect} has an invalid enum (must be an Array)"
            end
            validate_enum_values!(type, enum, tool_name: tool_name, parameter_name: name)
          end

          ignored = IGNORED_PROPERTY_KEYS.select { |key| schema.key?(key) }
          if ignored.any?
            warn_mcp(
              "[Phronomy] MCP tool '#{tool_name}' parameter '#{name}' has " \
              "constraint keywords #{ignored.inspect}; they will be ignored"
            )
          end

          unknown_property = schema.keys - SUPPORTED_PROPERTY_KEYS - IGNORED_PROPERTY_KEYS
          if unknown_property.any?
            raise Phronomy::ToolError,
              "MCP parameter #{name.inspect} uses unsupported schema keywords: " \
              "#{unknown_property.join(", ")}"
          end
        end

        def validate_enum_values!(type, values, tool_name:, parameter_name:)
          valid = values.all? do |value|
            case type
            when "string" then value.is_a?(String)
            when "integer" then value.is_a?(Integer)
            when "number" then value.is_a?(Numeric)
            when "boolean" then value == true || value == false
            end
          end
          return if valid

          raise Phronomy::ToolError,
            "MCP tool #{tool_name.inspect} parameter #{parameter_name.inspect} " \
            "has enum values incompatible with #{type}"
        end

        def warn_mcp(message)
          if Phronomy.configuration.logger
            Phronomy.configuration.logger.warn(message)
          else
            Kernel.warn(message)
          end
        end

        def close_transport_safely(transport)
          transport&.close
        rescue
          nil
        end
      end

      # @api private
      def initialize
        @mcp_call_mutex = Mutex.new
        @mcp_client = nil
        build_and_connect_client!
      end

      # Executes the remote MCP tool.
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @return [String, Array, Hash]
      # @api public
      def execute(cancellation_token: nil, **args)
        @mcp_call_mutex.synchronize do
          ensure_mcp_client!
          perform_mcp_call(cancellation_token: cancellation_token, args: args)
        end
      end

      # Closes the currently connected client synchronously. A transport already
      # detached after cancellation is owned by the Runtime cleanup pool and is
      # drained during Runtime shutdown; this method does not wait for that older
      # cleanup operation.
      #
      # The instance can be used again after close; the next call reconnects.
      # @return [void]
      # @api public
      def close
        @mcp_call_mutex.synchronize { invalidate_mcp_client! }
      end

      private

      def perform_mcp_call(cancellation_token:, args:)
        mcp_cancellation = build_mcp_cancellation(cancellation_token)
        response = begin
          @mcp_client.call_tool(
            name: self.class.tool_name,
            arguments: args.transform_keys(&:to_s),
            cancellation: mcp_cancellation
          )
        rescue MCP::CancelledError => e
          invalidate_mcp_client_after_cancellation!
          message = "MCP tool call was cancelled"
          message += ": #{e.reason}" if e.respond_to?(:reason) && e.reason
          raise Phronomy::CancellationError, message
        rescue MCP::Client::SessionExpiredError
          recover_expired_session!
        rescue MCP::Client::ServerError => e
          raise Phronomy::ToolError,
            "MCP server returned error (#{e.code}): #{e.message}"
        rescue MCP::Client::InputRequiredError => e
          raise Phronomy::ToolError,
            "MCP tool requires unsupported multi-round-trip input: #{e.message}"
        rescue MCP::Client::ValidationError => e
          raise Phronomy::ToolError,
            "MCP response validation failed: #{e.message}"
        rescue MCP::Client::RequestHandlerError => e
          raise Phronomy::ToolError,
            "MCP request handler failed: #{e.message}"
        rescue => e
          raise Phronomy::ToolError, "MCP call failed: #{e.message}"
        end

        result = validate_call_tool_response!(response)
        format_tool_result(result)
      end

      def build_mcp_cancellation(cancellation_token)
        return nil unless cancellation_token

        mcp_cancellation = MCP::Cancellation.new
        cancellation_token.on_cancel do
          mcp_cancellation.cancel(reason: "phronomy_cancelled")
        end
        mcp_cancellation
      end

      def recover_expired_session!
        begin
          @mcp_client.connect
        rescue => reconnect_error
          invalidate_mcp_client!
          raise Phronomy::ToolError,
            "MCP session expired and reconnection failed: #{reconnect_error.message}"
        end

        raise Phronomy::ToolError,
          "MCP session expired; the connection was restored, but the tool call was not replayed"
      end

      def validate_call_tool_response!(response)
        unless response.is_a?(Hash)
          raise Phronomy::ToolError, "MCP tool returned a non-object response"
        end

        result = response["result"]
        unless result.is_a?(Hash)
          raise Phronomy::ToolError, "MCP tool response is missing a valid result"
        end

        content = result["content"]
        unless content.is_a?(Array)
          raise Phronomy::ToolError, "MCP tool result is missing valid content"
        end
        unless content.all? { |item| item.is_a?(Hash) }
          raise Phronomy::ToolError,
            "MCP tool result contains an invalid content item"
        end
        if result.key?("isError") && result["isError"] != true && result["isError"] != false
          raise Phronomy::ToolError, "MCP tool result has an invalid isError value"
        end

        result
      end

      def format_tool_result(result)
        content = result.fetch("content")
        texts = content.filter_map do |item|
          item["text"] if item["type"] == "text" && item["text"].is_a?(String)
        end

        if result["isError"] == true
          message = texts.join("\n")
          message = JSON.generate(result["structuredContent"] || content) if message.empty?
          return "MCP tool execution error: #{message}"
        end

        return texts.first if texts.length == 1
        return texts if texts.any?

        result["structuredContent"] || content
      end

      def ensure_mcp_client!
        build_and_connect_client! unless @mcp_client
      end

      def build_and_connect_client!
        transport = nil
        begin
          uri = self.class.instance_variable_get(:@mcp_server_uri)
          headers = self.class.instance_variable_get(:@mcp_headers) || {}
          transport = self.class.send(:build_transport, uri, headers: headers)
          client = MCP::Client.new(transport: transport)
          client.connect
          @mcp_client = client
        rescue => e
          self.class.send(:close_transport_safely, transport)
          raise Phronomy::ToolError, "MCP connection failed: #{e.message}"
        end
      end

      def invalidate_mcp_client!
        old_client = @mcp_client
        @mcp_client = nil
        self.class.send(:close_transport_safely, old_client&.transport)
      end

      def invalidate_mcp_client_after_cancellation!
        old_client = @mcp_client
        @mcp_client = nil
        return unless old_client

        schedule_transport_cleanup(old_client.transport)
      end

      def schedule_transport_cleanup(transport)
        cleanup_pool = Phronomy::Runtime.instance.pool(
          :mcp_cleanup,
          size: MCP_CLEANUP_POOL_SIZE,
          queue_size: MCP_CLEANUP_QUEUE_SIZE
        )
        cleanup_pool.submit(on_full: :raise) do
          self.class.send(:close_transport_safely, transport)
        end
      rescue Phronomy::BackpressureError, Phronomy::PoolShutdownError
        # During shutdown or an exceptional cleanup burst, prefer a bounded
        # synchronous fallback over leaking the child process/socket.
        self.class.send(:close_transport_safely, transport)
      end
    end
  end
end
