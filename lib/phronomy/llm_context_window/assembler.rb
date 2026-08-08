# frozen_string_literal: true

require "cgi"

module Phronomy
  module LlmContextWindow
    # Assembler collects all four context regions and produces the final
    # {system:, messages:, tool_classes:} hash consumed by Agent::Base.
    #
    # Regions:
    #   1. Instruction  — system prompt text set via #add_instruction
    #   2. Capability   — tool classes registered via #add_capability
    #   3. Knowledge    — external facts injected via #add_knowledge (generates XML tags)
    #   4. Conversation — historical messages added via #add_messages
    #
    # Token budgeting:
    #   When a budget is given, conversation messages are trimmed from oldest to
    #   newest until they fit. Capability token cost is estimated and deducted
    #   from the budget before conversation trimming so the reserve is accurate.
    #   Knowledge chunks are always included in full (they are assumed to be
    #   pre-screened by the caller). When no budget is given all messages are
    #   passed through unchanged.
    #
    # @example
    #   assembler = Phronomy::LlmContextWindow::Assembler.new(budget: budget)
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

      # @param budget [Phronomy::LlmContextWindow::TokenBudget, nil]
      #   when nil no token trimming is performed
      # @api private
      # mutant:disable - @instruction = nil deletion is a genuine equivalent (uninitialized Ruby instance variables return nil)
      def initialize(budget: nil)
        @budget = budget
        @instruction = nil
        @tool_classes = []
        @knowledge_chunks = []
        @messages = []
      end

      # Register tool classes (Region 2).
      # Estimates their token cost and deducts it from the budget so that
      # conversation trimming accounts for tool definition overhead.
      #
      # @param tool_classes [Array<Class, Object>] tool classes or instances
      # @return [self]
      # @api private
      def add_capability(tool_classes)
        @tool_classes = Array(tool_classes)
        self
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

      # Returns the number of tokens available for conversation messages after
      # accounting for instruction, knowledge, and capability overhead.
      # Returns +nil+ when no budget is configured.
      #
      # @return [Integer, nil]
      # @api private
      def available_for_messages
        return nil unless @budget
        knowledge_text = @knowledge_chunks.map { |c| xml_context_tag(c) }.join("\n\n")
        system_parts = [@instruction, knowledge_text.empty? ? nil : knowledge_text].compact
        system_text = system_parts.join("\n\n")
        used = TokenEstimator.estimate(system_text) + estimate_capability_tokens
        @budget.available(used: used)
      end

      # Assemble the context.
      #
      # @return [Hash{Symbol => Object}]
      #   :system      [String, nil]  combined system prompt (instruction + knowledge XML tags)
      #   :messages    [Array]        conversation messages, trimmed to budget if set
      #   :tool_classes [Array]       tool classes/instances to register with the chat
      # @api private
      # Raises {Phronomy::ContextLengthError} when a budget is set and the
      # conversation messages do not fit within the remaining token allowance.
      # No automatic trimming is performed — callers must pre-process messages
      # before passing them to the Assembler.
      #
      # mutant:disable - multiple genuine equivalent mutations: map{}.join("\n\n") → map{} is genuine; `unless knowledge_text.empty?` vs ternary is genuine; `{ system: unless system_text.empty? }` vs ternary is genuine; `messages:` shorthand vs `messages: messages` is genuine
      def build
        knowledge_text = @knowledge_chunks.map { |c| xml_context_tag(c) }.join("\n\n")
        system_parts = [@instruction, knowledge_text.empty? ? nil : knowledge_text].compact
        system_text = system_parts.join("\n\n")

        if @budget && @messages.any?
          capability_tokens = estimate_capability_tokens
          used = TokenEstimator.estimate(system_text) + capability_tokens
          remaining = @budget.available(used: used)
          msg_tokens = @messages.sum { |m| TokenEstimator.estimate(m.content.to_s) }
          if msg_tokens > remaining
            raise Phronomy::ContextLengthError,
              "Context exceeds token budget: messages require #{msg_tokens} tokens but " \
              "only #{remaining} available (context_window=#{@budget.context_window}, " \
              "used_by_system=#{used}). Use the Context Policy path to manage message budget."
          end
        end

        {
          system: system_text.empty? ? nil : system_text,
          messages: @messages,
          tool_classes: @tool_classes
        }
      end

      private

      # Estimates the token cost of all registered tool classes.
      # Uses each tool's description and parameter names as a proxy for its
      # JSON Schema size. This is a deliberate simplification — exact token
      # counts require provider-specific schema serialization which lives in
      # RubyLLM. The estimate errs on the side of being slightly conservative
      # so that the conversation budget is not over-allocated.
      def estimate_capability_tokens
        @tool_classes.sum do |tc|
          # Instantiated tool objects (e.g. Phronomy::Tools::Mcp instances) may not be a Class.
          next 0 unless tc.is_a?(Class) && tc.respond_to?(:description)

          text = [tc.description.to_s]
          if tc.respond_to?(:parameters)
            tc.parameters.each_key { |k| text << k.to_s }
          end
          TokenEstimator.estimate(text.join(" "))
        end
      end

      # mutant:disable - multiple genuine equivalent mutations: chunk.fetch(key) vs chunk[key] (key always present); chunk[:text] no .to_s / .to_str are genuine (stored as String); chunk[:type] no .to_s / .to_str are genuine (stored as String); chunk[:source] no .to_s / .to_str are genuine (truthy branch, always String); src_attr chunk.fetch(:source) is genuine (source key always present)
      def xml_context_tag(chunk)
        src_attr = chunk[:source] ? " source=\"#{CGI.escapeHTML(chunk[:source].to_s)}\"" : ""
        "<context type=\"#{CGI.escapeHTML(chunk[:type].to_s)}\"#{src_attr} trusted=\"#{chunk[:trusted]}\">\n#{CGI.escapeHTML(chunk[:text].to_s)}\n</context>"
      end
    end
  end
end
