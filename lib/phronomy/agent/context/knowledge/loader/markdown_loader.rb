# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Knowledge
        module Loader
    # Loads a Markdown file, optionally splitting on top-level headings.
    #
    # When +split_on_headings:+ is true (the default), each H1/H2 section
    # becomes a separate document so that embeddings capture section semantics
    # rather than the full file at once.
    #
    # @example Single document (heading split disabled)
    #   loader = Phronomy::Agent::Context::Knowledge::Loader::MarkdownLoader.new(split_on_headings: false)
    #   docs   = loader.load("README.md")
    #   # => [{ text: "# Title\n...", metadata: { source: "README.md" } }]
    #
    # @example Split per heading (default)
    #   loader = Phronomy::Agent::Context::Knowledge::Loader::MarkdownLoader.new
    #   docs   = loader.load("guide.md")
    #   # => [
    #   #   { text: "# Section 1\n...", metadata: { source: "guide.md", section: "Section 1" } },
    #   #   { text: "## Sub-section\n...", metadata: { source: "guide.md", section: "Sub-section" } },
    #   # ]
    class MarkdownLoader < Base
      HEADING_RE = /^(\#{1,6})\s+(.+)$/

      # @param split_on_headings [Boolean] split on H1–H6 boundaries (default: true)
      # @api public
      def initialize(split_on_headings: true)
        @split_on_headings = split_on_headings
      end

      # @param source [String] path to a Markdown file
      # @return [Array<Hash>]
      # @raise [Errno::ENOENT] if the file does not exist
      # @api public
      def load(source)
        content = File.read(source, encoding: "UTF-8")
        return [{text: content, metadata: {source: source}}] unless @split_on_headings

        split_by_headings(content, source)
      end

      private

      def split_by_headings(content, source)
        sections = []
        current_lines = []
        current_heading = nil

        content.each_line do |line|
          if (m = HEADING_RE.match(line.chomp))
            flush_section(sections, current_lines, current_heading, source) if current_lines.any?
            current_heading = m[2].strip
            current_lines = [line]
          else
            current_lines << line
          end
        end

        flush_section(sections, current_lines, current_heading, source) if current_lines.any?

        # Fall back to single document if no headings were found
        sections.empty? ? [{text: content, metadata: {source: source}}] : sections
      end

      def flush_section(sections, lines, heading, source)
        text = lines.join
        return if text.strip.empty?

        metadata = {source: source}
        metadata[:section] = heading if heading
        sections << {text: text, metadata: metadata}
      end
    end
  end
end
end
end
end
