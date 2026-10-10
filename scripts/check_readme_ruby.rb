# frozen_string_literal: true

# Check all Ruby fences, including executable examples, in the entry documents.
require "tempfile"
require "open3"
require_relative "check_readme_runnable"

failures = []
count = 0
paths = ARGV.empty? ? RunnableDocumentation::PATHS : ARGV
paths.each do |relative|
  text = File.read(File.expand_path(relative, RunnableDocumentation::ROOT))
  text.to_enum(:scan, /^```ruby(?: runnable)?\n(.*?)^```/m).each do
    match = Regexp.last_match
    line = text[0...match.begin(1)].count("\n") + 1
    label = "#{relative}:#{line}"
    count += 1
    Tempfile.create(["documentation_block", ".rb"]) do |file|
      file.write(match[1])
      file.flush
      out, status = Open3.capture2e(RbConfig.ruby, "-c", file.path)
      if status.success?
        puts "OK   #{label}"
      else
        failures << label
        puts "FAIL #{label}"
        puts out.gsub(file.path, label)
      end
    end
  end
end
puts "#{count} Ruby blocks; #{failures.size} syntax failures"
exit(failures.empty? ? 0 : 1)
