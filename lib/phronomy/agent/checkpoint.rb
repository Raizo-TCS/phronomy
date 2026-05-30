# frozen_string_literal: true

module Phronomy
  module Agent
    # Encapsulates the suspended state of an agent invocation.
    #
    # A Checkpoint is returned as the +:checkpoint+ key of the result hash when
    # an approval-required tool is encountered and no synchronous
    # on_approval_required handler has been registered.
    #
    # Pass the checkpoint to Agent::Base#resume to continue execution after
    # obtaining an approval decision from the user or an external system.
    #
    # @example Suspend and resume
    #   result = agent.invoke("Do task X")
    #   if result[:suspended]
    #     approved = prompt_user(result[:checkpoint].pending_tool_name)
    #     result   = agent.resume(result[:checkpoint], approved: approved)
    #   end
    #   puts result[:output]
    class Checkpoint
      # @return [String, nil] the thread_id from the invocation config
      attr_reader :thread_id

      # @return [String, Hash] the original input passed to #invoke; stored so
      #   that #resume can re-apply dynamic system instructions (e.g. Proc or
      #   PromptTemplate-based instructions that depend on the input value).
      attr_reader :original_input

      # @return [Array<RubyLLM::Message>] conversation messages up to and including
      #   the assistant message that requested the pending tool call
      attr_reader :messages

      # @return [String] the name of the tool awaiting approval
      attr_reader :pending_tool_name

      # @return [Hash] the arguments the LLM passed to the pending tool
      attr_reader :pending_tool_args

      # @return [String] the tool_call_id from the LLM response (required to
      #   inject the tool result message on resume)
      attr_reader :pending_tool_call_id

      # @param thread_id            [String, nil]
      # @param original_input       [String, Hash] the input passed to the original #invoke call
      # @param messages             [Array<RubyLLM::Message>]
      # @param pending_tool_name    [String]
      # @param pending_tool_args    [Hash]
      # @param pending_tool_call_id [String]
      # @api public
      def initialize(thread_id:, original_input:, messages:, pending_tool_name:, pending_tool_args:, pending_tool_call_id:)
        @thread_id = thread_id
        @original_input = original_input
        @messages = messages.dup.freeze
        @pending_tool_name = pending_tool_name
        @pending_tool_args = pending_tool_args
        @pending_tool_call_id = pending_tool_call_id
      end

      # Converts this checkpoint to a plain Hash suitable for JSON / Marshal serialization.
      #
      # All values are plain Ruby objects (String, Symbol, Hash, Array, Numeric,
      # nil). +RubyLLM::Message+ objects in +:messages+ are deep-converted so that
      # any embedded +RubyLLM::ToolCall+ objects are also serialized as plain hashes.
      #
      # @example Round-trip via JSON
      #   json = JSON.generate(checkpoint.to_h)
      #   checkpoint2 = Phronomy::Agent::Checkpoint.from_h(JSON.parse(json))
      #
      # @return [Hash]
      # @api public
      def to_h
        {
          thread_id: @thread_id,
          original_input: @original_input,
          messages: @messages.map { |m| serialize_message(m) },
          pending_tool_name: @pending_tool_name,
          pending_tool_args: @pending_tool_args,
          pending_tool_call_id: @pending_tool_call_id
        }
      end

      # Reconstructs a +Checkpoint+ from a plain Hash (e.g. produced by {#to_h}
      # and deserialized from JSON or Marshal).
      #
      # Hash keys may be either Symbols or Strings; both are accepted.
      # +RubyLLM::ToolCall+ objects inside message +:tool_calls+ arrays are
      # reconstructed from their hash representations.
      #
      # @param h [Hash] a hash previously produced by {#to_h}
      # @return [Checkpoint]
      # @api public
      def self.from_h(h)
        h = h.transform_keys { |k| k.to_sym rescue k }
        messages = Array(h[:messages]).map { |m| deserialize_message(m) }
        new(
          thread_id: h[:thread_id],
          original_input: h[:original_input],
          messages: messages,
          pending_tool_name: h[:pending_tool_name]&.to_s,
          pending_tool_args: h[:pending_tool_args] ? h[:pending_tool_args].transform_keys { |k| k.to_sym rescue k } : {},
          pending_tool_call_id: h[:pending_tool_call_id]&.to_s
        )
      end

      private

      # Converts a +RubyLLM::Message+ to a plain Hash, ensuring that any
      # embedded +RubyLLM::ToolCall+ objects in +:tool_calls+ are also converted.
      #
      # @param msg [RubyLLM::Message]
      # @return [Hash]
      def serialize_message(msg)
        h = msg.to_h
        return h unless h[:tool_calls]

        h.merge(tool_calls: h[:tool_calls].map { |tc|
          tc.respond_to?(:to_h) ? tc.to_h : tc
        })
      end

      # Reconstructs a +RubyLLM::Message+ from a plain Hash.
      # +RubyLLM::ToolCall+ entries in +:tool_calls+ are re-instantiated.
      #
      # @param h [Hash]
      # @return [RubyLLM::Message]
      def self.deserialize_message(h)
        h = h.transform_keys { |k| k.to_sym rescue k }
        if h[:tool_calls]
          h = h.merge(tool_calls: Array(h[:tool_calls]).map { |tc|
            next tc if tc.is_a?(RubyLLM::ToolCall)

            tc = tc.transform_keys { |k| k.to_sym rescue k }
            RubyLLM::ToolCall.new(
              id: tc[:id].to_s,
              name: tc[:name].to_s,
              arguments: (tc[:arguments] || {}).transform_keys { |k| k.to_sym rescue k },
              thought_signature: tc[:thought_signature]
            )
          })
        end
        RubyLLM::Message.new(h)
      end
    end
  end
end
