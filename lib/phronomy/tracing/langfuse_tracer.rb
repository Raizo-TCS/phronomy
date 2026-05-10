# frozen_string_literal: true

require "net/http"
require "json"
require "base64"
require "securerandom"

module Phronomy
  module Tracing
    # Langfuse tracer adapter.
    #
    # Sends spans to Langfuse via the batch ingestion REST API
    # (+POST /api/public/ingestion+).  No external gem is required — only
    # Ruby standard-library network primitives are used.
    #
    # Ingestion errors are silently swallowed so that a Langfuse outage never
    # breaks the application.
    #
    # @example Configure globally
    #   Phronomy.configure do |c|
    #     c.tracer = Phronomy::Tracing::LangfuseTracer.new(
    #       public_key: ENV.fetch("LANGFUSE_PUBLIC_KEY"),
    #       secret_key: ENV.fetch("LANGFUSE_SECRET_KEY"),
    #       host:       ENV.fetch("LANGFUSE_HOST", "https://cloud.langfuse.com")
    #     )
    #   end
    class LangfuseTracer < Base
      # Default Langfuse cloud host.
      DEFAULT_HOST = "https://cloud.langfuse.com"

      # @param public_key [String] Langfuse project public key
      # @param secret_key [String] Langfuse project secret key
      # @param host [String] Langfuse host URL (override for self-hosted instances)
      def initialize(public_key:, secret_key:, host: DEFAULT_HOST)
        @public_key = public_key
        @secret_key = secret_key
        @host = host.chomp("/")
      end

      # Returns a plain Hash that records the span start state.
      #
      # @return [Hash] an opaque span handle used by {#finish_span}
      def start_span(name, input: nil, **meta)
        {
          id: SecureRandom.uuid,
          trace_id: SecureRandom.uuid,
          name: name,
          input: input,
          start_time: Time.now,
          meta: meta
        }
      end

      # Serialises the span and fires it to Langfuse via the ingestion API.
      def finish_span(span, output: nil, usage: nil, error: nil)
        body = {
          id: span[:id],
          traceId: span[:trace_id],
          name: span[:name],
          startTime: span[:start_time].utc.iso8601(3),
          endTime: Time.now.utc.iso8601(3),
          input: span[:input],
          output: error ? nil : output,
          metadata: span[:meta]
        }
        body[:level] = "ERROR" if error
        body[:statusMessage] = error.message if error
        if usage
          body[:usage] = {
            input: usage.input,
            output: usage.output,
            total: (usage.input || 0) + (usage.output || 0)
          }
        end
        ingest([{type: "span-create", body: body}])
      end

      private

      # Sends a batch of events to the Langfuse ingestion endpoint.
      # Errors are rescued and ignored to keep the tracer non-disruptive.
      def ingest(events)
        uri = URI.parse("#{@host}/api/public/ingestion")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 3
        http.read_timeout = 5
        req = Net::HTTP::Post.new(uri.request_uri)
        req["Content-Type"] = "application/json"
        req["Authorization"] = "Basic #{Base64.strict_encode64("#{@public_key}:#{@secret_key}")}"
        req.body = JSON.generate({batch: events})
        http.request(req)
      rescue
        nil
      end
    end
  end
end
