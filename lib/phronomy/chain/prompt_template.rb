# frozen_string_literal: true

require "erb"

module Phronomy
  module Chain
    # Prompt generation component based on ERB templates.
    # invoke accepts a Hash of template variables and returns { system:, user: }.
    class PromptTemplate
      include Phronomy::Runnable

      # @param template [String] ERB template for the user prompt
      # @param system_template [String, nil] ERB template for the system prompt
      def initialize(template: nil, system_template: nil)
        @template = template
        @system_template = system_template
      end

      # @param input [Hash] template variables
      # @return [Hash] { system: String, user: String } (nil fields omitted)
      def invoke(input, config: {})
        vars = input.is_a?(Hash) ? input : {}
        result = {}
        result[:system] = render(@system_template, vars) if @system_template
        result[:user] = render(@template, vars) if @template
        result
      end

      # Builds an instance by loading templates from files.
      # @param path [String] file path for the user prompt template
      # @param system_path [String, nil] file path for the system prompt template
      def self.from_file(path, system_path: nil)
        new(
          template: File.read(path),
          system_template: system_path ? File.read(system_path) : nil
        )
      end

      # Builds a system prompt by combining named sections.
      # @param sections [Hash] e.g. { role: "...", task: "...", behavior: "..." }
      def self.with_sections(**sections)
        template = sections.map { |name, content| "# #{name.to_s.upcase}\n#{content}" }.join("\n\n")
        new(system_template: template)
      end

      private

      def render(template, vars)
        ERB.new(template).result_with_hash(vars)
      end
    end
  end
end
