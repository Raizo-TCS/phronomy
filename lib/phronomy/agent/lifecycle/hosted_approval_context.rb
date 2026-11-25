# frozen_string_literal: true

require "weakref"

module Phronomy
  module Agent
    # Captures the original hosted parent's authority before a child decision
    # is submitted. Saved evidence is immutable; later handles use only the same
    # live owners and never reconstruct authority from diagnostic identities.
    # @api private
    class HostedApprovalContext
      attr_reader :parent_evidence

      def initialize(parent:, child:, parent_wait:, parent_evidence:, reader:)
        @parent_reference = WeakRef.new(parent)
        @child_reference = WeakRef.new(child)
        @parent_wait_reference = WeakRef.new(parent_wait)
        @parent_agent_id = parent.agent_id.to_s.dup.freeze
        @parent_execution_id = parent_wait.execution_id.to_s.dup.freeze
        @parent_revision = parent_wait.revision
        @child_agent_id = child.agent_id.to_s.dup.freeze
        @parent_evidence = parent_evidence
        @wait = parent_evidence.wait
        @reader = reader
        @mutex = Mutex.new
        @released = false
      end

      # Only the canonical continuation's physical end (or restored pre-state)
      # retires this authority. A failed original observer cannot release it.
      def release!
        @mutex.synchronize do
          @released = true
          @reader = @parent_evidence = nil
          @parent_reference = @child_reference = @parent_wait_reference = nil
        end
      end

      # EventLoop application checks only local ownership. Guarded Store reads
      # are performed separately by the approval persistence worker.
      def validate_live!
        parent, child, parent_wait, = live_owners
        environment = parent.__execution_environment
        owner = environment.registry.agent_execution_owner(@wait.execution_id)
        unless parent_wait.current? && parent_wait.execution_id == @parent_execution_id &&
            parent.agent_id == @parent_agent_id && child.agent_id == @child_agent_id &&
            child.__execution_environment.registry.equal?(environment.registry) &&
            owner&.agent.equal?(child)
          raise Phronomy::AgentBusyError, "Original hosted approval authority is no longer current"
        end
        true
      rescue WeakRef::RefError
        raise Phronomy::AgentBusyError, "Original hosted approval owner is no longer available"
      end

      # The observation may close independently. Only the exact canonical task
      # carries the decision's right to detach a later approval wait.
      def build_invocation(observation:, detach_task:)
        parent_reference = @mutex.synchronize { @parent_reference unless @released }
        return unless parent_reference
        parent = parent_reference.__getobj__
        HostedInvocation.new(parent, @parent_execution_id, observation,
          resumed_from: @wait, detach_task: detach_task) do |execution_id, approval_id|
          validate_live!
          _, child, _, reader = live_owners
          reader.call(@parent_agent_id, @parent_execution_id, execution_id, approval_id,
            parent_revision: @parent_revision, live_child: child)
        end
      rescue WeakRef::RefError
        # A historical recovery receipt still observes execution after its host
        # has disappeared. It cannot issue a replacement detach capability.
        nil
      end

      private

      def live_owners
        @mutex.synchronize do
          raise Phronomy::AgentBusyError, "Hosted approval authority has finished" if @released
          [@parent_reference.__getobj__, @child_reference.__getobj__,
            @parent_wait_reference.__getobj__, @reader]
        end
      end
    end
  end
end
