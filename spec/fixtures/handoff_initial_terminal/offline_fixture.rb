# frozen_string_literal: true

require_relative "application"

module HandoffTerminalApplication
  module OfflineFixture
    class RejectedResponsibility < Phronomy::Filter::Base
      def call(value, **_context)
        raise ArgumentError, "Review rejected case-42" if value == "reject case-42"
        value
      end
    end
    ReviewAgent.input_filter RejectedResponsibility

    class Adapter < Phronomy::LLMAdapter::Base
      attr_reader :requests

      def initialize(tool_name: nil, responsibility: nil, responses: nil)
        @requests = []
        @responses = responses || [
          Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
            Phronomy::Tool::CallRequest.new(id: "delegate-case-42", name: tool_name,
              arguments: {"responsibility" => responsibility})
          ]),
          Phronomy::LLMAdapter::Response.new(content: "case-42 reviewed", finish_reason: :stop)
        ]
      end

      protected

      def perform_complete(request, cancellation_token:)
        @requests << request
        @responses.shift || raise("unexpected Provider replay")
      end
    end

    # This complete fixture supplies deterministic Provider responses. It never
    # constructs an HTTP client or sends the model declaration to a live service.
    def self.run(version:, reject:)
      session = HandoffTerminalApplication.open_session(handoff: true)
      binding = Phronomy::MultiAgent::HandoffCapabilityFactory.build(session.fetch(:edge))
      adapter = Adapter.new(tool_name: binding.tool_name,
        responsibility: reject ? "reject case-42" : "review case-42")
      Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
      work = HandoffTerminalApplication.run_example("case-42", version: version, session: session)
      {work: work, adapter: adapter}
    end
  end
end
