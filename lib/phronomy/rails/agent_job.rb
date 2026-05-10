# frozen_string_literal: true

module Phronomy
  module Rails
    # ActiveJob-based job that runs a Phronomy agent in streaming mode and
    # broadcasts each event to an ActionCable stream.
    #
    # Enqueue with +perform_later+ to run the agent asynchronously in a background
    # worker. Every streaming event is forwarded to ActionCable subscribers in
    # real time.
    #
    # @example Enqueueing a streaming agent job
    #   Phronomy::Rails::AgentJob.perform_later(
    #     "MyAgent",
    #     "What is the weather today?",
    #     channel: "AgentChannel",
    #     stream: "agent_#{current_user.id}"
    #   )
    #
    # Events broadcast to the ActionCable stream:
    #   { type: "token",   content: "..." }  — each content delta from the LLM
    #   { type: "done",    output:  "..." }  — final complete output
    #   { type: "error",   message: "..." }  — when the agent or job raises
    #
    class AgentJob < ::ActiveJob::Base
      # @param agent_class_name [String]
      #   The constantize-able class name of the agent to run (e.g. "MyAgent").
      # @param input [String, Hash]
      #   User input forwarded unchanged to the agent's +#stream+ method.
      # @param channel [String]
      #   ActionCable channel name. Retained for documentation / future routing.
      # @param stream [String]
      #   ActionCable stream identifier passed to +ActionCable.server.broadcast+.
      # @param config [Hash]
      #   Configuration forwarded to the agent's +#stream+ call. Both symbol and
      #   string keys are accepted; all keys are converted to symbols before use.
      def perform(agent_class_name, input, channel:, stream:, config: {})
        agent = Object.const_get(agent_class_name).new
        agent.stream(input, config: config.transform_keys(&:to_sym)) do |event|
          ActionCable.server.broadcast(stream, build_payload(event))
        end
      rescue => e
        ActionCable.server.broadcast(stream, {type: "error", message: e.message})
      end

      private

      def build_payload(event)
        case event.type
        when :token then {type: "token", content: event.payload[:content]}
        when :done then {type: "done", output: event.payload[:output]}
        when :error then {type: "error", message: event.payload[:error]&.message}
        else {type: event.type.to_s}
        end
      end
    end
  end
end
