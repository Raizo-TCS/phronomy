# frozen_string_literal: true

module Phronomy
  module Agent
    # ReAct pattern (Reasoning + Acting) agent.
    # Repeats the LLM <-> Tool loop until no more tool calls are made.
    class ReactAgent < Base
      def invoke(input, config: {})
        # Run input guardrails before any LLM interaction.
        run_input_guardrails!(input)

        memory = config[:memory]
        thread_id = config[:thread_id]
        max_iter = self.class.max_iterations

        # Seed with persisted messages when memory is provided.
        initial_messages = if memory && thread_id
          memory.load_messages(thread_id: thread_id)
        else
          []
        end

        messages = initial_messages.dup
        user_asked = false
        total_usage = Phronomy::TokenUsage.zero

        max_iter.times do
          response = step(messages, input, user_asked: user_asked)
          user_asked = true
          messages = response[:messages]
          total_usage += response[:usage]
          break if response[:done]
        end

        memory.save_messages(thread_id: thread_id, messages: messages) if memory && thread_id

        output = messages.last&.content

        # Run output guardrails before returning to the caller.
        run_output_guardrails!(output)

        {output: output, messages: messages, usage: total_usage}
      end

      # Streaming version of #invoke for the ReAct loop.
      # Yields {Phronomy::Agent::StreamEvent} events while the LLM-tool loop runs.
      #
      # @param input  [String, Hash]
      # @param config [Hash]
      # @yield [Phronomy::Agent::StreamEvent]
      # @return [Hash] { output:, messages:, usage: }
      def stream(input, config: {}, &block)
        return invoke(input, config: config) unless block

        run_input_guardrails!(input)

        memory = config[:memory]
        thread_id = config[:thread_id]
        max_iter = self.class.max_iterations

        initial_messages = if memory && thread_id
          memory.load_messages(thread_id: thread_id)
        else
          []
        end

        messages = initial_messages.dup
        user_asked = false
        total_usage = Phronomy::TokenUsage.zero

        max_iter.times do
          response = stream_step(messages, input, user_asked: user_asked, &block)
          user_asked = true
          messages = response[:messages]
          total_usage += response[:usage]
          break if response[:done]
        end

        memory.save_messages(thread_id: thread_id, messages: messages) if memory && thread_id

        output = messages.last&.content
        run_output_guardrails!(output)

        result = {output: output, messages: messages, usage: total_usage}
        block.call(StreamEvent.new(type: :done, payload: result))
        result
      rescue => e
        block.call(StreamEvent.new(type: :error, payload: {error: e}))
        raise
      end

      private

      def step(messages, initial_input, user_asked: false)
        chat = build_chat

        # Inject any existing history (from previous loop iterations or loaded memory).
        messages.each { |m| chat.add_message(m) }

        response = if user_asked
          # Subsequent loop iteration — history already contains the user message;
          # just ask the LLM to continue (e.g. after a tool result).
          chat.complete
        else
          # First iteration — add the new user question and call the LLM.
          chat.ask(extract_message(initial_input))
        end

        usage = Phronomy::TokenUsage.from_tokens(response&.tokens)
        tool_calls = chat.messages.last&.tool_calls
        done = tool_calls.nil? || tool_calls.empty?
        {messages: chat.messages, done: done, usage: usage}
      end

      # Streaming variant of #step.  Yields :token / :tool_call / :tool_result events
      # via the block while the LLM call is in progress.
      def stream_step(messages, initial_input, user_asked: false, &block)
        chat = build_chat
        messages.each { |m| chat.add_message(m) }

        chat.on_tool_call { |tc| block.call(StreamEvent.new(type: :tool_call, payload: {tool_call: tc})) }
        chat.on_tool_result { |tr| block.call(StreamEvent.new(type: :tool_result, payload: {tool_result: tr})) }

        streaming_block = proc { |chunk| block.call(StreamEvent.new(type: :token, payload: {content: chunk.content})) }

        response = if user_asked
          chat.complete(&streaming_block)
        else
          chat.ask(extract_message(initial_input), &streaming_block)
        end

        usage = Phronomy::TokenUsage.from_tokens(response&.tokens)
        tool_calls = chat.messages.last&.tool_calls
        done = tool_calls.nil? || tool_calls.empty?
        {messages: chat.messages, done: done, usage: usage}
      end
    end
  end
end
