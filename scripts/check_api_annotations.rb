#!/usr/bin/env ruby
# frozen_string_literal: true

# check_api_annotations.rb
#
# Verifies that every YARD-documented public method in lib/ carries either
# "@api public" or "@api private".
#
# A method is considered "YARD-documented" when its preceding comment block
# contains at least one @param, @return, @raise, @yield, @example, or
# @overload tag.  Methods with only a plain prose description (no @ tags)
# are exempt.
#
# Usage (run from the phronomy/ repository root):
#   ruby scripts/check_api_annotations.rb
#
# Exit codes:
#   0 — all documented methods carry @api annotations
#   1 — one or more documented methods are missing @api annotations

lib_dir = File.expand_path("../lib", __dir__)

unless File.directory?(lib_dir)
  warn "ERROR: lib directory not found at #{lib_dir}"
  exit 1
end

errors = []

Dir.glob(File.join(lib_dir, "**", "*.rb")).sort.each do |file|
  lines = File.readlines(file)

  lines.each_with_index do |line, i|
    next unless line.match?(/^\s*def\s+\w/)

    # Collect the contiguous comment block immediately above this def.
    comment_lines = []
    j = i - 1
    while j >= 0 && lines[j].match?(/^\s*#/)
      comment_lines.unshift(lines[j])
      j -= 1
    end

    next if comment_lines.empty?

    comment = comment_lines.join

    # Only lint methods that carry at least one YARD type tag.
    next unless comment.match?(/#[ \t]+@(param|return|raise|yield|example|overload)/)

    # Pass if an @api tag is already present.
    next if comment.match?(/#[ \t]+@api[ \t]+(public|private)/)

    rel_path = file.sub("#{lib_dir}/../", "")
    m = line.match(/def\s+(\w+[!?=]?)/)
    method_name = m ? m[1] : "unknown"
    errors << "#{rel_path}:#{i + 1}  def #{method_name}  (missing @api public or @api private)"
  end
end

if errors.empty?
  puts "OK: all YARD-documented methods carry @api annotations"
  exit 0
else
  puts "FAIL: #{errors.size} method(s) missing @api annotation:"
  errors.each { |e| puts "  #{e}" }
  exit 1
end
