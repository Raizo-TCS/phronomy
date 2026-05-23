# frozen_string_literal: true

# scripts/check_readme_runnable.rb
#
# Extracts ```ruby runnable blocks from README.md and executes each in an
# isolated subprocess with a fake LLM stub to catch API drift.
#
# Any block that raises NoMethodError / ArgumentError / NameError causes a
# non-zero exit, failing the CI step.
#
# Usage (from the phronomy/ root):
#   bundle exec ruby scripts/check_readme_runnable.rb

require "tempfile"
require "open3"

REPO_ROOT = File.expand_path("..", __dir__)
README_PATH = File.join(REPO_ROOT, "README.md")

# Injected before every runnable block.
# Uses the Gemfile of this project so subprocesses can load phronomy.
PREAMBLE = <<~RUBY
  # frozen_string_literal: true
  # --- CI preamble: stub LLM calls so no real network requests are made ---
  ENV["BUNDLE_GEMFILE"] ||= "#{File.join(REPO_ROOT, "Gemfile")}"
  require "bundler/setup"
  require "phronomy"

  # Patch invoke methods to return canned responses instead of calling the LLM.
  module Phronomy
    module Agent
      class Base
        def invoke(input = nil, **)
          {output: "ci-stub-output", messages: []}
        end
      end

      class Runner
        def invoke(input = nil, **)
          {output: "ci-stub-output", agent: nil, messages: []}
        end
      end
    end

    module Chain
      class LLMChain
        def invoke(vars = {})
          "ci-stub-chain"
        end
      end
    end
  end
  # --- end CI preamble ---

RUBY

readme = File.read(README_PATH)

# Match opening fence with 'runnable' annotation: ```ruby runnable
blocks = readme.scan(/^```ruby runnable\n(.*?)^```/m).map.with_index(1) { |(code), i| [i, code] }

if blocks.empty?
  puts "No 'ruby runnable' blocks found in README.md."
  exit 0
end

puts "Checking #{blocks.size} runnable Ruby block(s) in README.md..."

failures = []

blocks.each do |index, code|
  Tempfile.create(["readme_runnable_#{index}", ".rb"]) do |f|
    f.write(PREAMBLE)
    f.write(code)
    f.flush

    out, err, status = Open3.capture3(RbConfig.ruby, f.path)
    combined = (out + err).gsub(f.path, "block ##{index}")

    if status.success?
      puts "  OK   block ##{index}"
    else
      failures << index
      puts "  FAIL block ##{index}"
      # Print at most 15 lines of output to keep CI logs readable.
      puts combined.lines.first(15).join
    end
  end
end

puts
if failures.empty?
  puts "All #{blocks.size} runnable block(s) passed."
  exit 0
else
  puts "#{failures.size} block(s) failed: #{failures.join(", ")}"
  exit 1
end
