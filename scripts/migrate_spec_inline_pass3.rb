#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds agent_definition to single-line inline anonymous blocks like:
# Class.new(Phronomy::Agent::Base) { model "test-model" }

counter = 300
files = Dir.glob("spec/**/*.rb").sort

files.each do |f|
  content = File.read(f)
  modified = content.gsub(
    /Class\.new\(Phronomy::Agent::Base\) \{ ([^{}]+) \}/
  ) do
    body = $1
    next $& if body.include?("agent_definition")
    counter += 1
    "Class.new(Phronomy::Agent::Base) { agent_definition id: \"test-agent-#{counter}\", version: 1; #{body} }"
  end
  if modified != content
    File.write(f, modified)
    puts "  patched: #{f}"
  end
end
