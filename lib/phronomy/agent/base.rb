# frozen_string_literal: true

module Phronomy
  module Agent
    class Base
      include Phronomy::Runnable

      class << self
        def model(name = nil)
          if name
            @model = name
          else
            @model || Phronomy.configuration.default_model
          end
        end

        def instructions(text = nil, &block)
          if text || block_given?
            @instructions = text || block
          else
            @instructions
          end
        end

        def tools(*tool_classes)
          if tool_classes.any?
            @tools = tool_classes
          else
            @tools || []
          end
        end

        def provider(name = nil)
          if name
            @provider = name
          else
            @provider
          end
        end

        def temperature(val = nil)
          if val
            @temperature = val
          else
            @temperature
          end
        end

        def max_iterations(val = nil)
          if val
            @max_iterations = val
          else
            @max_iterations || 10
          end
        end
      end

      def invoke(input, config: {})
        # Run input guardrails before touching the LLM.
        run_input_guardrails!(input)

        memory    = config[:memory]
        thread_id = config[:thread_id]

        chat = build_chat
        system_msg = build_instructions(input)
        chat.with_instructions(system_msg) if system_msg

        # Inject previous messages from memory before asking.
        if memory && thread_id
          memory.load_messages(thread_id: thread_id).each do |msg|
            chat.messages << msg
          end
        end

        user_message = extract_message(input)
        response = chat.ask(user_message)

        # Persist the updated conversation to memory.
        memory.save_messages(thread_id: thread_id, messages: chat.messages) if memory && thread_id

        output = response.content

        # Run output guardrails before returning to the caller.
        run_output_guardrails!(output)

        {output: output, messages: chat.messages}
      end

      # Attach a guardrail that validates input before every #invoke call.
      # @param guardrail [Phronomy::Guardrail::InputGuardrail]
      def add_input_guardrail(guardrail)
        @input_guardrails ||= []
        @input_guardrails << guardrail
        self
      end

      # Attach a guardrail that validates output before it is returned.
      # @param guardrail [Phronomy::Guardrail::OutputGuardrail]
      def add_output_guardrail(guardrail)
        @output_guardrails ||= []
        @output_guardrails << guardrail
        self
      end

      private

      def build_chat
        opts = {}
        m = self.class.model
        opts[:model] = m if m
        p = self.class.provider
        if p
          opts[:provider] = p
          opts[:assume_model_exists] = true
        end
        t = self.class.temperature
        opts[:temperature] = t if t
        chat = RubyLLM.chat(**opts)
        self.class.tools.each { |tool| chat.with_tool(tool) }
        chat
      end

      def build_instructions(input)
        instr = self.class.instructions
        case instr
        when String then instr
        when Proc then instr.call(input)
        when nil then nil
        end
      end

      def extract_message(input)
        case input
        when String then input
        when Hash then input[:message] || input[:query] || input[:user] || input.to_s
        else input.to_s
        end
      end

      def run_input_guardrails!(input)
        (@input_guardrails || []).each { |g| g.run!(input) }
      end

      def run_output_guardrails!(output)
        (@output_guardrails || []).each { |g| g.run!(output) }
      end
    end
  end
end
