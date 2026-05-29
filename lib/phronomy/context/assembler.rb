# frozen_string_literal: true

require "cgi"

module Phronomy
  module Context
    # Assembler collects all four context regions and produces the final
    # {system:, messages:} hash consumed by Agent::Base.
    #
    # Regions:
    #   1. Instruction  — system prompt text set via #add_instruction
    #   2. Capability   — tool definitions (handled by RubyLLM, not here)
    #   3. Knowledge    — external facts injected via #add_knowledge (generates XML tags)
    #   4. Conversation — historical messages added via #add_messages
    #
    # Token budgeting:
    #   When a budget is given, conversation messages are trimmed from oldest to
    #   newest until they fit. Knowledge chunks are always included in full (they
    #   are assumed to be pre-screened by the caller). When no budget is given all
    #   messages are passed through unchanged.
    #
    # @example
    #   assembler = Phronomy::Context::Assembler.new(budget: budget)
    #   assembler.add_instruction("You are a helpful assistant.")
    #   assembler.add_knowledge("The user lives in Tokyo.", type: :entity, trusted: false)
    #   assembler.add_messages(manager.load(thread_id: "t1", query: user_input))
    #   context = assembler.build
    #   # => { system: "You are ...\n<context ...>...</context>", messages: [...] }
    class Assembler
      # Builds a single XML context tag string.
      # Exposed as a class method so callers (e.g. Agent::Base) can build
      # static knowledge XML tags independently of an Assembler instance.
      #
      # @param text    [String]
      # @param type    [Symbol, String]
      # @param trusted [Boolean]
      # @return [String]
      # @api private
      # mutant:disable - text.to_str and plain text (no to_s) are genuine equivalents when text is a String; type.to_str is genuine equivalent when type is a String
      def self.xml_tag(text, type:, trusted: false)
        "<context type=\"#{CGI.escapeHTML(type.to_s)}\" trusted=\"#{trusted}\">\n#{CGI.escapeHTML(text.to_s)}\n</context>"
      end

      # @param budget [Phronomy::Context::TokenBudget, nil]
      #   when nil no token trimming is performed
      # @api private
      # mutant:disable - @instruction = nil deletion is a genuine equivalent (uninitialized Ruby instance variables return nil)
      def initialize(budget: nil)
        @budget = budget
        @instruction = nil
        @knowledge_chunks = []
        @messages = []
      end

      # Set the system instruction text (Region 1).
      # Calling this multiple times replaces the previous value.
      #
      # @param text [String]
      # @return [self]
      # @api private
      # mutant:disable - text.to_str and plain text (no .to_s) are genuine equivalents when callers always pass a String
      def add_instruction(text)
        @instruction = text.to_s
        self
      end

      # Append a knowledge chunk (Region 3).
      # The chunk is wrapped in an XML context tag automatically.
      #
      # @param text    [String]
      # @param type    [Symbol, String]  semantic label for the context tag (e.g. :entity, :rag, :static)
      # @param trusted [Boolean]         false (default) indicates externally sourced data
      # @param source  [String, nil]     optional source label (e.g. filename); included in the
      #   XML tag so the LLM can produce grounded citations. Omitted when nil.
      # @return [self]
      # @api private
      # mutant:disable - {text:} (shorthand, no .to_s) and text.to_str are genuine equivalents when text is a String; {type:} shorthand is genuine equivalent because xml_context_tag always calls .to_s on chunk[:type]
      def add_knowledge(text, type:, trusted: false, source: nil)
        @knowledge_chunks << {text: text.to_s, type: type.to_s, trusted: trusted, source: source}
        self
      end

      # Set conversation messages (Region 4). Replaces any previously set messages.
      #
      # @param messages [Array] message-like objects with #role and #content
      # @return [self]
      # @api private
      # mutant:disable - @messages = messages (no Array()) is a genuine equivalent when callers always pass an Array
      def add_messages(messages)
        @messages = Array(messages)
        self
      end

      # Assemble the context.
      #
      # @return [Hash{Symbol => Object}]
      #   :system   [String, nil]  combined system prompt (instruction + knowledge XML tags)
      #   :messages [Array]        conversation messages, trimmed to budget if set
      # @api private
      # mutant:disable - multiple genuine equivalent mutations: map{}.join("\n\n") → map{} is genuine because Ruby Array#join recursively joins nested arrays with the same separator (so [outer_array].join("\n\n") == original String); `unless knowledge_text.empty?` vs ternary is genuine (same conditional logic); `{ system: unless system_text.empty? }` vs ternary is genuine; `messages:` shorthand vs `messages: messages` is genuine
      def build
        knowledge_text = @knowledge_chunks.map { |c| xml_context_tag(c) }.join("\n\n")
        system_parts = [@instruction, knowledge_text.empty? ? nil : knowledge_text].compact
        system_text = system_parts.join("\n\n")

        messages = if @budget
          trim_messages_to_budget(@messages, system_text)
        else
          @messages
        end

        {
          system: system_text.empty? ? nil : system_text,
          messages: messages
        }
      end

      private

      # mutant:disable - multiple genuine equivalent mutations: chunk.fetch(key) vs chunk[key] (key always present); chunk[:text] no .to_s / .to_str are genuine (stored as String); chunk[:type] no .to_s / .to_str are genuine (stored as String); chunk[:source] no .to_s / .to_str are genuine (truthy branch, always String); src_attr chunk.fetch(:source) is genuine (source key always present)
      def xml_context_tag(chunk)
        src_attr = chunk[:source] ? " source=\"#{CGI.escapeHTML(chunk[:source].to_s)}\"" : ""
        "<context type=\"#{CGI.escapeHTML(chunk[:type].to_s)}\"#{src_attr} trusted=\"#{chunk[:trusted]}\">\n#{CGI.escapeHTML(chunk[:text].to_s)}\n</context>"
      end

      # mutant:disable - multiple genuine equivalent mutations on the early-return guard:
      # `remaining <= 0 && false/nil`, `if false`, `if nil`, `if remaining && messages.empty?`,
      # `if remaining < 0 && messages.empty?`, `if remaining <= -1 && messages.empty?`,
      # `if remaining <= 1 && messages.empty?`, `if remaining == 0 && messages.empty?`,
      # `if remaining.eql?(0) && messages.empty?`, `if remaining.equal?(0) && messages.empty?`,
      # `if 0 && messages.empty?`, `if nil && messages.empty?` —
      # all are genuine equivalents because when messages.empty? the loop produces [] anyway,
      # and remaining is always >= 0 (clamp(0..)) so `remaining < 0` / `<= -1` are never true.
      def trim_messages_to_budget(messages, system_text)
        used = TokenEstimator.estimate(system_text)
        remaining = @budget.available(used: used)
        return messages if remaining <= 0 && messages.empty?

        accumulated = 0
        result = []
        messages.reverse_each do |msg|
          tokens = TokenEstimator.estimate(msg.content.to_s)
          break if accumulated + tokens > remaining

          accumulated += tokens
          result.push(msg)
        end

        if result.empty? && messages.any?
          warn "[Phronomy::Assembler] All #{messages.length} conversation message(s) dropped: " \
               "token budget exhausted by system context (budget=#{@budget.context_window}, used_by_system=#{used})"
        end

        result.reverse
      end
    end
  end
end
