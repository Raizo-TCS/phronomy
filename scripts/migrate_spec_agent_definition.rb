#!/usr/bin/env ruby
# frozen_string_literal: true

# Migrates spec files to add agent_definition to Agent::Base subclasses.
# - Named classes: inserts after the class declaration line
# - Anonymous blocks (do...end): inserts after the opening `do`
# - Inline anonymous ({ ... }): expands to multi-line with agent_definition
# Safe: skips classes that already have agent_definition

require "fileutils"

SPEC_DIR = File.expand_path("../spec", __dir__)
AGENT_BASE_PATTERN = /Phronomy::Agent::Base/

def snake_case(class_name)
  # Remove trailing Agent/Tool suffixes, snake_case the name
  name = class_name.split("::").last
  name = name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
  name
end

counter = 0
files_modified = 0

Dir.glob("#{SPEC_DIR}/**/*.rb").sort.each do |file|
  lines = File.readlines(file, chomp: false)
  new_lines = []
  modified = false
  i = 0

  while i < lines.length
    line = lines[i]

    # ── Named class: class FooAgent < Phronomy::Agent::Base ──────────────────
    if line =~ /^(\s*)class\s+(\w+)\s*<\s*(?:::)?Phronomy::Agent::Base\s*$/
      indent = $1
      class_name = $2
      id = snake_case(class_name).sub(/_agent$/, "-agent").tr("_", "-")
      id = "#{id}-agent" unless id.end_with?("-agent")
      new_lines << line
      i += 1
      # Check if agent_definition already present in the class body
      look_ahead = lines[i..]&.take(10) || []
      unless look_ahead.any? { |l| l =~ /agent_definition/ }
        new_lines << "#{indent}  agent_definition id: #{id.inspect}, version: 1\n"
        counter += 1
        modified = true
      end
      next
    end

    # ── Anonymous block (do...end): Class.new(Phronomy::Agent::Base) do ─────
    if line =~ /^(\s*)([\w.]*\s*=\s*)?Class\.new\((?:::)?Phronomy::Agent::Base\)\s+do\s*(\|\w+\|)?\s*$/
      indent = $1
      # Check if agent_definition already present
      look_ahead = lines[i + 1..]&.take(10) || []
      new_lines << line
      i += 1
      unless look_ahead.any? { |l| l =~ /agent_definition/ }
        # Derive indentation from the `do` block body (first non-blank line)
        inner = lines[i..]&.take(5)&.find { |l| l.strip.length > 0 } || ""
        inner_indent = inner.match(/^(\s*)/)[1]
        inner_indent = "#{indent}  " if inner_indent.strip.length > 0 && inner_indent.length < indent.length + 2
        new_lines << "#{inner_indent}agent_definition id: \"test-agent-#{counter += 1}\", version: 1\n"
        modified = true
      end
      next
    end

    # ── Inline anonymous: Class.new(Phronomy::Agent::Base) { ... } ───────────
    if line =~ /^(\s*)((?:[\w.]*\s*=\s*)?)Class\.new\((?:::)?Phronomy::Agent::Base\)\s*\{(.+)\}\s*$/
      indent = $1
      assignment = $2
      body = $3
      # Skip if agent_definition already present
      if body =~ /agent_definition/
        new_lines << line
      else
        id = counter += 1
        definition_line = "agent_definition id: \"test-agent-#{id}\", version: 1;"
        new_lines << "#{indent}#{assignment}Class.new(Phronomy::Agent::Base) do\n"
        new_lines << "#{indent}  #{definition_line}\n"
        # Rewrite the original body lines, stripping leading spaces
        body.strip.split(";").each do |stmt|
          stmt = stmt.strip
          next if stmt.empty?
          new_lines << "#{indent}  #{stmt}\n"
        end
        new_lines << "#{indent}end\n"
        modified = true
      end
      i += 1
      next
    end

    new_lines << line
    i += 1
  end

  if modified
    File.write(file, new_lines.join)
    files_modified += 1
    puts "  patched: #{file.sub("#{SPEC_DIR}/", "spec/")}"
  end
end

puts "\nDone: #{counter} agent_definition insertions in #{files_modified} files."
