# frozen_string_literal: true

module Phronomy
  module Agent
    # Retains exact parent/child sessions across partial approval continuation.
    # Accepted session identities are never rebuilt or registered again.
    # @api private
    class ApprovalContinuationPlan
      attr_reader :parent_id

      def initialize(environment:, invocation:, result_task:, approved:, config:, on_complete:, cancel_requested: false)
        @environment, @invocation, @result_task = environment, invocation, result_task
        @approved, @config, @on_complete = approved, config, on_complete
        @configured = false
        @captured_cancellation = cancel_requested
        @original_token = invocation.config[:cancellation_token]
        parent = environment.build_agent_session(invocation: invocation,
          resume_event: :resume, resume_phase: :suspended)
        @parent_id = parent.id
        source = Phronomy::TaskResult.deferred(name: "#{result_task.name}-source")
        source.on_complete do |value, error|
          @cancellation&.close
          @on_complete.call(execution_id: invocation.execution_id,
            result_task: result_task, invocation: value || invocation,
            error: error, fsm_session_id: parent.id)
        end
        @sessions = [{session: parent, completion: source, accepted: false, unknown: false}]
        invocation.tool_invocations.each do |child|
          event, phase = if child.awaiting_approval?
            [approved ? :approve : :reject, :awaiting_approval]
          elsif !approved && child.authorized?
            [:cancel, :authorized]
          end
          next unless event
          session = environment.build_tool_session(invocation: child,
            parent_sink: parent.event_sink, resume_event: event, resume_phase: phase)
          completion = Phronomy::TaskResult.deferred(name: "tool-session:#{child.id}")
          completion.on_complete do |_value, error|
            next unless error
            child.mark_framework_failed!(error)
            parent.event_sink.post(:tool_failed, {tool_invocation_id: child.id})
          end
          @sessions << {session: session, completion: completion, accepted: false, unknown: false}
        end
      end

      def resume
        unless @environment.executing?
          raise Phronomy::Error, "Approval continuation must run on its original EventLoop"
        end
        unless @configured
          @invocation.merge_config!(@config)
          @invocation.begin_approval_resume!(approved: @approved)
          @configured = true
        end
        @environment.registry.replace_agent_execution(@invocation.execution_id,
          invocation: @invocation, fsm_session_id: parent_id)
        register(@sessions.first)
        # A cancelled retained partial plan wakes its accepted parent. It never
        # starts the remaining children merely to manufacture their completion.
        @sessions.drop(1).each { |record| register(record) } unless cancellation_requested? && !complete?
        self
      ensure
        if parent_accepted? && !complete?
          bind_parent_cancellation
        elsif complete?
          @cancellation&.close
        end
      end

      def complete? = @sessions.all? { |record| record[:accepted] || record[:abandoned] }
      def uncertain? = @sessions.any? { |record| record[:unknown] }
      def parent_accepted? = @sessions.first[:accepted]

      # A terminal parent needs no newly started children. Only registrations
      # positively known not to have happened can be abandoned by that handoff.
      def finish_parent(fsm_session_id)
        return false unless parent_accepted? && fsm_session_id.to_s == parent_id.to_s && !uncertain?
        @sessions.each { |record| record[:abandoned] = true unless record[:accepted] }
        true
      end

      private

      def cancellation_tokens
        [@original_token, @invocation.config[:cancellation_token]].compact.uniq
      end

      def cancellation_requested? = @captured_cancellation || cancellation_tokens.any?(&:cancelled?)

      def bind_parent_cancellation
        return if @cancellation
        @cancellation = Phronomy::Concurrency::Subscriptions.new
        sink = @sessions.first.fetch(:session).event_sink
        cancel = lambda do
          sink.post(:approval_resume_cancelled,
            {error: Phronomy::CancellationError.new("Agent execution cancelled during approval continuation")})
        end
        cancellation_tokens.each do |token|
          @cancellation.cancellation(token, &cancel)
        end
        cancel.call if @captured_cancellation
      end

      def register(record)
        return if record[:accepted] || record[:abandoned]
        if record[:unknown]
          raise Phronomy::Error, "Approval session registration has no authoritative admission receipt"
        end
        register_once(record)
      end

      def register_once(record)
        received = @environment.register_session(record[:session], completion: record[:completion])
        raise Phronomy::Error, "Approval session registration returned no receipt" unless received
        record[:accepted] = true
      rescue => error
        # This query is made immediately on the same EventLoop, before queued
        # session events can run. A later absent session must never grant replay.
        admitted = begin
          @environment.session_admitted?(record[:session].id) if @environment.respond_to?(:session_admitted?)
        rescue
          nil
        end
        record[:accepted] = true if admitted == true
        record[:unknown] = true unless admitted == true || admitted == false
        raise error
      end
    end
  end
end
