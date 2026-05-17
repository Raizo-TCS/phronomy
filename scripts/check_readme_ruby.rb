# frozen_string_literal: true

# Extracts every ```ruby ... ``` block from README.md and runs `ruby -c` on each.
# Exits non-zero if any block has a syntax error.

require "tempfile"
require "open3"

readme_path = File.expand_path("../README.md", __dir__)
readme      = File.read(readme_path)
blocks      = readme.scan(/^```ruby\n(.*?)^```/m).map.with_index(1) { |(code), i| [i, code] }

puts "Checking #{blocks.size} Ruby code blocks in README.md..."

failures = []

blocks.each do |index, code|
  Tempfile.create(["readme_block_#{index}", ".rb"]) do |f|
    f.write(code)
    f.flush
    stdout, status = Open3.capture2e("ruby", "-c", f.path)
    if status.success?
      puts "  OK   block ##{index}"
    else
      failures << index
      puts "  FAIL block ##{index}"
      puts stdout.gsub(f.path, "block ##{index}")
    end
  end
end

if failures.empty?
  puts "All #{blocks.size} Ruby code blocks passed syntax check."
  exit 0
else
  puts "\n#{failures.size} block(s) failed syntax check: #{failures.join(", ")}"
  exit 1
end
