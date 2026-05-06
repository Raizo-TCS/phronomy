# frozen_string_literal: true

module Phronomy
  module Agent
    # ReAct pattern (Reasoning + Acting) agent.
    # Repeats the LLM <-> Tool loop until no more tool calls are made.
    class ReactAgent < Base
      def invoke(input, config: {})
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

        max_iter.times do
          response = step(messages, input, user_asked: user_asked)
          user_asked = true
          messages = response[:messages]
          break if response[:done]
        end

        memory.save_messages(thread_id: thread_id, messages: messages) if memory && thread_id

        {output: messages.last&.content, messages: messages}
      end

      private

      def step(messages, initial_input, user_asked: false)
        chat = build_chat

        # Inject any existing history (from previous loop iterations or loaded memory).
        messages.each { |m| chat.add_message(m) }

        if user_asked
          # Subsequent loop iteration — history already contains the user message;
          # just ask the LLM to continue (e.g. after a tool result).
          chat.complete
        else
          # First iteration — add the new user question and call the LLM.
          chat.ask(extract_message(initial_input))
        end

        tool_calls = chat.messages.last&.tool_calls
        done = tool_calls.nil? || tool_calls.empty?
        {messages: chat.messages, done: done}
      end
    end
  end
end
