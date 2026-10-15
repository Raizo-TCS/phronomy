# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    # One application-visible Tool approval notification, scoped to an invocation.
    # The C04 request carries display-safe details. Generation only routes replies.
    class Approval
      attr_reader :invocation_id, :phase, :request

      def initialize(invocation:, operation:, phase:, request:)
        @invocation, @operation = invocation, operation
        @invocation_id, @phase, @request = invocation.id, phase, request
        freeze
      end

      def respond_async(approved:)
        unless approved == true || approved == false
          return Phronomy::TaskResult.failed(ArgumentError.new("approved must be true or false"))
        end
        @invocation.respond(self) do
          @operation.approve_async(@request, approved: approved)
        end.map { nil }
      end

      def to_h
        {invocation_id: @invocation_id, phase: @phase.to_s, request: @request.to_h}
      end
    end
  end
end
