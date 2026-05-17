# frozen_string_literal: true

module Phronomy
  module Agent
    # ReAct pattern (Reasoning + Acting) agent.
    # Repeats the LLM <-> Tool loop until no more tool calls are made.
    class ReactAgent < Base
      private

      # Performs a single (non-retried) ReAct invocation.
      # Overrides Base#invoke_once so that Base#invoke's retry loop is inherited.
      def invoke_once(input, config: {})
        caller_meta = {}
        caller_meta[:user_id] = config[:user_id] if config[:user_id]
        caller_meta[:session_id] = config[:session_id] if config[:session_id]

        trace("agent.invoke", input: input, **caller_meta) do |_span|
          # Run input guardrails before any LLM interaction.
          run_input_guardrails!(input)

          thread_id = config[:thread_id]
          max_iter = self.class.max_iterations

          # Seed with app-managed conversation history when provided.
          messages = Array(config[:messages]).dup
          user_asked = false
          total_usage = Phronomy::TokenUsage.zero
          iterations_exhausted = true

          max_iter.times do
            response = step(messages, input, user_asked: user_asked, config: config)
            user_asked = true
            messages = response[:messages]
            total_usage += response[:usage]
            if response[:done]
              iterations_exhausted = false
              break
            end
          end

          # Fall back to the last message
          # guards against the case where the final message is a tool-call or
          output = messages.reverse.find { |m| m.content && !m.content.empty? }&.content

          # Run output guardrails before returning to the caller.
          run_output_guardrails!(output)

          result = {output: output, messages: messages, usage: total_usage, iterations_exhausted: iterations_exhausted}
          [result, total_usage]
        end
      end

      public

      # Streaming version of #invoke for the ReAct loop.
      # Yields {Phronomy::Agent::StreamEvent} events while the LLM-tool loop runs.
      #
      # @param input  [String, Hash]
      # @param config [Hash]
      # @yield [Phronomy::Agent::StreamEvent]
      # @return [Hash] { output:, messages:, usage: }
      def stream(input, config: {}, &block)
        return invoke(input, config: config) unless block

        caller_meta = {}
        caller_meta[:user_id] = config[:user_id] if config[:user_id]
        caller_meta[:session_id] = config[:session_id] if config[:session_id]

        trace("agent.invoke", input: input, **caller_meta) do |_span|
          run_input_guardrails!(input)

          thread_id = config[:thread_id]
          max_iter = self.class.max_iterations

          messages = Array(config[:messages]).dup
          user_asked = false
          total_usage = Phronomy::TokenUsage.zero
          iterations_exhausted = true

          max_iter.times do
            response = stream_step(messages, input, user_asked: user_asked, config: config, &block)
            user_asked = true
            messages = response[:messages]
            total_usage += response[:usage]
            if response[:done]
              iterations_exhausted = false
              break
            end
          end

          # Fall back to the last message that carries non-nil content (same as
          # the non-streaming path above).
          output = messages.reverse.find { |m| m.content && !m.content.empty? }&.content
          run_output_guardrails!(output)

          result = {output: output, messages: messages, usage: total_usage, iterations_exhausted: iterations_exhausted}
          block.call(StreamEvent.new(type: :done, payload: result))
          [result, total_usage]
        end
      rescue => e
        block&.call(StreamEvent.new(type: :error, payload: {error: e}))
        raise
      end

      private

      def step(messages, initial_input, user_asked: false, config: {})
        chat = build_chat

        # Inject any existing history (from previous loop iterations or loaded memory).
        messages.each { |m| chat.add_message(m) }

        # Run before_completion hooks before each LLM call in the ReAct loop.
        run_before_completion_hooks!(chat, config)

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
      def stream_step(messages, initial_input, user_asked: false, config: {}, &block)
        chat = build_chat
        messages.each { |m| chat.add_message(m) }

        current_tool_call = nil
        chat.on_tool_call do |tc|
          current_tool_call = tc
          block.call(StreamEvent.new(type: :tool_call, payload: {tool_call: tc}))
        end
        chat.on_tool_result do |tr|
          block.call(StreamEvent.new(type: :tool_result, payload: {
            tool_call_id: current_tool_call&.id,
            tool_name: current_tool_call&.name,
            tool_result: tr
          }))
        end

        # Run before_completion hooks before each LLM call in the streaming loop.
        run_before_completion_hooks!(chat, config)

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
