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

        # Registers tool classes for this agent.
        #
        # Accepts either a splat of classes (backward-compatible) or a Hash mapping
        # each class to an explicit alias name (String) or nil (use tool's own name).
        # The alias form is useful when two tools share the same auto-generated name
        # (e.g. two SearchTool classes from different modules).
        #
        # @example Splat form (no alias)
        #   tools WeatherTool, TimeTool
        #
        # @example Hash form (with optional per-tool alias)
        #   tools(
        #     Weather::SearchTool => "weather_search",
        #     Places::SearchTool  => "places_search",
        #     CurrentTimeTool     => nil
        #   )
        def tools(*args)
          if args.empty?
            return @tools || []
          end

          if args.length == 1 && args.first.is_a?(Hash)
            hash = args.first
            @tools = hash.keys
            @tool_aliases = hash.transform_values { |v| v&.to_s }.reject { |_, v| v.nil? }
          else
            @tools = args
            @tool_aliases = {}
          end
        end

        # Returns the alias map registered via the hash form of .tools.
        # @return [Hash{Class => String}]
        def tool_aliases
          @tool_aliases ||= {}
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

        # When enabled, attaches Anthropic prompt-cache markers to the system
        # message so that the fixed instructions are served from cache on
        # subsequent turns, reducing input-token costs.
        #
        # Only has an effect when the agent also declares `provider :anthropic`.
        # The cache_control field is provider-specific (the format differs
        # between Anthropic direct, Bedrock, etc.), so the agent must explicitly
        # declare its provider via the DSL rather than having it inferred from
        # the model name.
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     provider :anthropic
        #     cache_instructions true
        #   end
        def cache_instructions(enabled = nil)
          if enabled.nil?
            @cache_instructions
          else
            @cache_instructions = enabled
          end
        end

        # Tokens to reserve for the model's output.
        # When nil, the model's max_output_tokens from the registry is used.
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     max_output_tokens 4096
        #   end
        def max_output_tokens(val = nil)
          if val.nil?
            @max_output_tokens
          else
            @max_output_tokens = val.to_i
          end
        end

        # Tokens reserved for the system prompt + tool definitions overhead.
        # Subtract this from the context window before computing the memory budget.
        #
        # @example
        #   class MyAgent < Phronomy::Agent::Base
        #     context_overhead 500
        #   end
        def context_overhead(val = nil)
          if val.nil?
            @context_overhead || 0
          else
            @context_overhead = val.to_i
          end
        end
      end

      def invoke(input, config: {})
        # Run input guardrails before touching the LLM.
        run_input_guardrails!(input)

        memory = config[:memory]
        thread_id = config[:thread_id]

        chat = build_chat
        system_msg = build_instructions(input)
        apply_instructions(chat, system_msg) if system_msg

        # Inject previous messages from memory before asking.
        if memory && thread_id
          token_budget = build_token_budget
          memory.load_messages(thread_id: thread_id, token_budget: token_budget).each do |msg|
            chat.messages << msg
          end
        end

        user_message = extract_message(input)
        response = chat.ask(user_message)

        # Persist the updated conversation to memory.
        memory.save_messages(thread_id: thread_id, messages: chat.messages) if memory && thread_id

        output = response.content
        usage = Phronomy::TokenUsage.from_tokens(response.tokens)

        # Run output guardrails before returning to the caller.
        run_output_guardrails!(output)

        {output: output, messages: chat.messages, usage: usage}
      end

      # Streaming version of #invoke. Yields {Phronomy::Agent::StreamEvent} objects
      # as they are produced by the underlying LLM.
      #
      # Events emitted (in order):
      #   :token       — each content delta from the LLM
      #   :tool_call   — when the LLM requests a tool (ReactAgent subclasses only)
      #   :tool_result — after a tool completes (ReactAgent subclasses only)
      #   :done        — final event carrying output, messages, and usage
      #   :error       — if an unrecoverable error occurs
      #
      # @param input  [String, Hash] same as #invoke
      # @param config [Hash]        same as #invoke
      # @yield [Phronomy::Agent::StreamEvent]
      # @return [Hash] { output:, messages:, usage: } — same as #invoke
      def stream(input, config: {}, &block)
        return invoke(input, config: config) unless block

        run_input_guardrails!(input)

        memory = config[:memory]
        thread_id = config[:thread_id]

        chat = build_chat
        system_msg = build_instructions(input)
        apply_instructions(chat, system_msg) if system_msg

        if memory && thread_id
          token_budget = build_token_budget
          memory.load_messages(thread_id: thread_id, token_budget: token_budget).each do |msg|
            chat.messages << msg
          end
        end

        # Wire per-event callbacks to yield StreamEvents.
        chat.on_tool_call { |tool_call| block.call(StreamEvent.new(type: :tool_call, payload: {tool_call: tool_call})) }
        chat.on_tool_result { |tool_result| block.call(StreamEvent.new(type: :tool_result, payload: {tool_result: tool_result})) }

        user_message = extract_message(input)
        response = chat.ask(user_message) do |chunk|
          block.call(StreamEvent.new(type: :token, payload: {content: chunk.content}))
        end

        memory.save_messages(thread_id: thread_id, messages: chat.messages) if memory && thread_id

        output = response.content
        usage = Phronomy::TokenUsage.from_tokens(response.tokens)

        run_output_guardrails!(output)

        result = {output: output, messages: chat.messages, usage: usage}
        block.call(StreamEvent.new(type: :done, payload: result))
        result
      rescue => e
        block.call(StreamEvent.new(type: :error, payload: {error: e}))
        raise
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

      # Builds a TokenBudget for this agent's model if possible.
      # Returns nil when the model is not registered in RubyLLM (e.g. local/unknown models).
      def build_token_budget
        model_name = self.class.model
        return nil unless model_name

        Phronomy::Context::TokenBudget.new(
          model: model_name,
          max_output_tokens: self.class.max_output_tokens,
          overhead: self.class.context_overhead
        )
      rescue Phronomy::Context::UnknownModelError, RubyLLM::ModelNotFoundError
        nil
      end

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
        chat = RubyLLM.chat(**opts)
        chat.with_temperature(t) if t
        self.class.tools.each do |tool_class|
          alias_name = self.class.tool_aliases[tool_class]
          if alias_name
            # Build an anonymous subclass that overrides tool_name with the alias.
            # Class-level instance variables (@description, @params, etc.) are NOT
            # automatically inherited in Ruby, so copy them explicitly.
            parent_description = tool_class.description
            aliased = Class.new(tool_class) do
              tool_name alias_name
              description parent_description if parent_description
            end
            chat.with_tool(aliased)
          else
            chat.with_tool(tool_class)
          end
        end
        chat
      end

      def build_instructions(input)
        instr = self.class.instructions
        case instr
        when Phronomy::Chain::PromptTemplate
          vars = input.is_a?(Hash) ? input : {input: input}
          instr.format_system(**vars) || instr.format(**vars)
        when String then instr
        when Proc then instr.call(input)
        when nil then nil
        end
      end

      # Applies system instructions to a chat object.
      # When cache_instructions is enabled and the provider is Anthropic,
      # attaches a cache_control marker so that the fixed system prompt is
      # eligible for prompt caching.
      def apply_instructions(chat, text)
        if self.class.cache_instructions && anthropic_provider?
          content = RubyLLM::Providers::Anthropic::Content.new(text, cache: true)
          chat.with_instructions(content)
        else
          chat.with_instructions(text)
        end
      end

      # Returns true when this agent explicitly declares `provider :anthropic`.
      # Provider is intentionally checked via the DSL value rather than inferred
      # from the model name, because cache_control format is API-endpoint-specific
      # (Anthropic direct vs. Bedrock vs. OpenRouter all differ).
      def anthropic_provider?
        self.class.provider == :anthropic
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
