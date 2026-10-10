# frozen_string_literal: true

# Runs annotated, self-contained examples through the real public API.
# Only the external LLM adapter is replaced. Each block has its own process,
# configuration and Runtime; an accidental network request fails immediately.
# Usage: bundle exec ruby scripts/check_readme_runnable.rb [markdown paths...]
require "tempfile"
require "open3"

module RunnableDocumentation
  ROOT = File.expand_path("..", __dir__)
  PATHS = %w[README.md docs/getting-started.md docs/application-recipes.md docs/workflow-completion.md].freeze

  PREAMBLE = <<~RUBY
    require "bundler/setup"
    require "phronomy"
    require "webmock"
    require "timeout"
    WebMock.enable!
    WebMock.disable_net_connect!

    class DocumentationLLM < Phronomy::LLMAdapter::Base
      protected

      def perform_complete(request, cancellation_token:)
        previous = request.messages.last
        if previous&.role == :tool
          return Phronomy::LLMAdapter::Response.new(content: previous.content)
        end

        search = request.tools.find do |tool|
          tool.fetch("parameters_schema").fetch("properties", {}).key?("query")
        end
        if search
          return Phronomy::LLMAdapter::Response.new(tool_calls: [
            Phronomy::Tool::CallRequest.new(
              id: SecureRandom.uuid, name: search.fetch("name"),
              arguments: {"query" => "Ruby AI frameworks"}
            )
          ])
        end

        Phronomy::LLMAdapter::Response.new(content: "ci-stub-output")
      end

      def perform_stream(request, cancellation_token:)
        response = perform_complete(request, cancellation_token: cancellation_token)
        yield Phronomy::LLMAdapter::StreamChunk.new(content: response.content) if response.content
        response
      end
    end
  RUBY

  def self.blocks(path)
    text = File.read(path)
    text.to_enum(:scan, /^```ruby runnable\n(.*?)^```/m).map do
      match = Regexp.last_match
      [text[0...match.begin(1)].count("\n") + 1, match[1]]
    end
  end

  def self.check(paths = PATHS, output: $stdout)
    failures = []
    count = 0
    paths.each do |relative|
      path = File.expand_path(relative, ROOT)
      examples = blocks(path)
      if examples.empty?
        failures << relative
        output.puts "FAIL #{relative}: no ruby runnable blocks"
      end
      examples.each do |line, code|
        count += 1
        label = "#{relative}:#{line}"
        Tempfile.create(["phronomy_documentation", ".rb"]) do |file|
          file.write(PREAMBLE)
          file.write(<<~RUBY)
            Phronomy.with_configuration do |configuration|
              configuration.llm_adapter = DocumentationLLM.new
              begin
                Timeout.timeout(20) do
                  eval(#{code.dump}, TOPLEVEL_BINDING, #{path.dump}, #{line})
                end
              ensure
                Phronomy::Runtime.reset_default!(timeout: 5)
              end
            end
          RUBY
          file.flush
          out, err, status = Open3.capture3(
            {"BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile")},
            RbConfig.ruby, file.path, chdir: ROOT
          )
          if status.success?
            output.puts "OK   #{label}"
          else
            failures << label
            output.puts "FAIL #{label}"
            output.puts (out + err).gsub(file.path, label).lines.first(15).join
          end
        end
      end
    end
    output.puts "#{count} runnable examples; #{failures.size} failures"
    failures.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  paths = ARGV.empty? ? RunnableDocumentation::PATHS : ARGV
  exit(RunnableDocumentation.check(paths) ? 0 : 1)
end
