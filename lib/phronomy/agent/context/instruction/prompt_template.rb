# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Instruction
        # A prompt template that substitutes {{variable}} placeholders in a string.
        #
        # @example Simple human template
        #   t = Phronomy::Agent::Context::Instruction::PromptTemplate.new(template: "Translate to {{lang}}: {{text}}")
        #   t.format(lang: "French", text: "Hello")
        #   # => "Translate to French: Hello"
        #
        # @example With a system template
        #   t = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
        #     template: "{{question}}",
        #     system_template: "You are a {{role}} assistant."
        #   )
        #   t.format_system(role: "helpful")
        #   # => "You are a helpful assistant."
        #
        # As a Runnable, #invoke accepts a Hash of variables and returns a Hash
        # with :prompt (and optionally :system) keys.
        class PromptTemplate
          include Phronomy::Runnable

          PLACEHOLDER = /\{\{(\w+)\}\}/

          attr_reader :template, :system_template

          # @param template        [String] human message template with {{var}} placeholders
          # @param system_template [String, nil] optional system message template
          # @api public
          def initialize(template:, system_template: nil)
            @template = template
            @system_template = system_template
          end

          # Substitute all {{var}} placeholders in the human template.
          #
          # @param variables [Hash{Symbol => String}]
          # @return [String]
          # @api public
          def format(**variables)
            substitute(@template, variables)
          end

          # Substitute all {{var}} placeholders in the system template.
          # Returns nil when no system template was set.
          #
          # @param variables [Hash{Symbol => String}]
          # @return [String, nil]
          # @api public
          def format_system(**variables)
            @system_template && substitute(@system_template, variables)
          end

          # Runnable interface: accepts a Hash of variable values.
          # Returns { prompt: String, system: String|nil }.
          #
          # @param input  [Hash{Symbol => String}]
          # @return [Hash]
          # @api public
          def invoke(input, config: {})
            vars = normalize_input(input)
            result = {prompt: format(**vars)}
            sys = format_system(**vars)
            result[:system] = sys if sys
            result
          end

          # Returns the list of placeholder names found in both templates.
          #
          # @return [Array<Symbol>]
          # @api public
          def variables
            names = @template.scan(PLACEHOLDER).flatten
            names += @system_template.scan(PLACEHOLDER).flatten if @system_template
            names.map(&:to_sym).uniq
          end

          private

          def substitute(text, variables)
            text.gsub(PLACEHOLDER) do |match|
              key = Regexp.last_match(1).to_sym
              variables.fetch(key) { raise KeyError, "Missing variable: {{#{key}}}" }
            end
          end

          def normalize_input(input)
            case input
            when Hash then input
            when String then {input: input}
            else raise ArgumentError, "PromptTemplate#invoke expects a Hash of variables, got #{input.class}"
            end
          end
        end
      end
    end
  end
end
