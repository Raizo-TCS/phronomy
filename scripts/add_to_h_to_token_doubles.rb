#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds to_h to all Tokens-like doubles so ExecutionCoordinator can serialize usage.

files = Dir.glob("spec/**/*.rb").sort

total = 0
files.each do |f|
  content = File.read(f)
  modified = content.gsub(
    /double\(("[^"]+"),\s*(input: \d+, output: \d+, cached: \d+, cache_creation: \d+)\)/
  ) do
    name = $1
    attrs = $2
    next $& if $&.include?("to_h")

    h_entries = attrs.split(",").map(&:strip).map do |pair|
      k, v = pair.split(":").map(&:strip)
      "\"#{k}\" => #{v}"
    end.join(", ")

    total += 1
    "double(#{name}, #{attrs}, to_h: {#{h_entries}})"
  end

  if modified != content
    File.write(f, modified)
    puts "  patched: #{f}"
  end
end

puts "\nAdded to_h to #{total} Tokens doubles."
