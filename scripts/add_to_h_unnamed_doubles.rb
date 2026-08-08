#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds to_h to unnamed (no-string-name) Tokens doubles like double(input: 5, ...)

files = Dir.glob("spec/**/*.rb").sort

total = 0
files.each do |f|
  content = File.read(f)
  modified = content.gsub(
    /double\((input: (\d+), output: (\d+), cached: (\d+), cache_creation: (\d+))\)/
  ) do
    attrs, a, b, c, d = $1, $2, $3, $4, $5
    next $& if $&.include?("to_h")

    total += 1
    "double(#{attrs}, to_h: {\"input\" => #{a}, \"output\" => #{b}, \"cached\" => #{c}, \"cache_creation\" => #{d}})"
  end

  if modified != content
    File.write(f, modified)
    puts "  patched: #{f}"
  end
end

puts "\nAdded to_h to #{total} unnamed Tokens doubles."
