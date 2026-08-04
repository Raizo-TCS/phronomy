#!/usr/bin/env ruby
# frozen_string_literal: true

# Second pass: handles patterns missed by the first script
#   - Class.new(Phronomy::Agent::Base) { ... }.new  (inline + .new suffix)
#   - Class.new(Phronomy::Agent::Base).new           (no block + .new)
#   - { Class.new(Phronomy::Agent::Base) }           (no block, inside outer { })

require "fileutils"

SPEC_DIR = File.expand_path("../spec", __dir__)
counter = 200

files_modified = 0

Dir.glob("#{SPEC_DIR}/**/*.rb").sort.each do |file|
  content = File.read(file)
  new_content = content.dup
  modified = false

  # Pattern A: Class.new(Phronomy::Agent::Base) { body }.new
  new_content = new_content.gsub(
    /Class\.new\(Phronomy::Agent::Base\) \{([^}]*)\}\.new/
  ) do
    body = $1
    next $& if body.include?("agent_definition")
    counter += 1
    "Class.new(Phronomy::Agent::Base) { agent_definition id: \"test-agent-#{counter}\", version: 1;#{body}}.new"
  end

  # Pattern B: Class.new(Phronomy::Agent::Base).new  (no block, chained .new)
  new_content = new_content.gsub(
    /Class\.new\(Phronomy::Agent::Base\)\.new\b/
  ) do
    counter += 1
    "Class.new(Phronomy::Agent::Base) { agent_definition id: \"test-agent-#{counter}\", version: 1 }.new"
  end

  # Pattern C: { Class.new(Phronomy::Agent::Base) }  (no block, inside outer block)
  new_content = new_content.gsub(
    /\{ Class\.new\(Phronomy::Agent::Base\) \}/
  ) do
    counter += 1
    "{ Class.new(Phronomy::Agent::Base) { agent_definition id: \"test-agent-#{counter}\", version: 1 } }"
  end

  if new_content != content
    File.write(file, new_content)
    files_modified += 1
    modified = true
    puts "  patched: #{file.sub("#{SPEC_DIR}/", "spec/")}"
  end
end

puts "\nSecond pass done: #{files_modified} files modified."
