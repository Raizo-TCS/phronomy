# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      # Conversation history management — the fourth region of the Agent context
      # window as defined by ADR-011.
      #
      # The four regions are:
      #   1. Instruction  — system prompt
      #   2. Capability   — tool definitions
      #   3. Knowledge    — external facts (RAG / vector search results)
      #   4. Conversation — this module (conversation history trim / compaction)
      #
      # Classes auto-loaded by Zeitwerk:
      #   Phronomy::Agent::Context::Conversation::TrimContext
      #   Phronomy::Agent::Context::Conversation::TriggerContext
      #   Phronomy::Agent::Context::Conversation::CompactionContext
      module Conversation
      end
    end
  end
end
