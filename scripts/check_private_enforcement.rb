#!/usr/bin/env ruby
# frozen_string_literal: true

# check_private_enforcement.rb
#
# Verifies that every instance method annotated @api private in lib/ is
# actually non-public at the Ruby level (i.e., NOT in Module#public_instance_methods).
#
# Class methods (def self.xxx) are excluded from this check because their
# visibility is managed separately on the singleton class and rarely causes
# accidental public exposure to consumers.
#
# Usage (run from the phronomy/ repository root):
#   bundle exec ruby scripts/check_private_enforcement.rb
#
# Exit codes:
#   0 — all @api private instance methods are non-public (or have no Ruby def)
#   1 — one or more @api private instance methods are exposed as public

require "bundler/setup"
require_relative "../lib/phronomy"

lib_dir = File.expand_path("../lib", __dir__)

unless File.directory?(lib_dir)
  warn "ERROR: lib directory not found at #{lib_dir}"
  exit 1
end

# Step 1: Collect instance methods annotated @api private via static analysis.
api_private_entries = []

Dir.glob(File.join(lib_dir, "**", "*.rb")).sort.each do |file|
  lines = File.readlines(file)

  lines.each_with_index do |line, i|
    next unless line.match?(/^\s*#\s*@api\s+private\s*$/)

    # Advance past any further comment or blank lines to reach the def.
    j = i + 1
    j += 1 while j < lines.size && lines[j].match?(/^\s*(#|$)/)
    next unless j < lines.size

    # Skip class-level methods — they live on the singleton class, not as
    # public instance methods accessible to consumers.
    next if lines[j].match?(/def\s+self\./)

    # Match both plain def and "private def".
    m = lines[j].match(/^\s*(?:private\s+)?def\s+(\w+[!?=]?)/)
    next unless m

    rel_path = file.sub("#{lib_dir}/../", "")
    api_private_entries << {name: m[1].to_sym, file: rel_path, line: j + 1}
  end
end

if api_private_entries.empty?
  puts "No @api private instance methods found."
  exit 0
end

# Step 2: Build a map of publicly exposed instance methods across all
# Phronomy-namespaced modules/classes (own methods only, no inheritance).
all_phronomy_modules = ObjectSpace.each_object(Module).select do |mod|
  mod.name&.start_with?("Phronomy")
end

public_exposure_map = {}
all_phronomy_modules.each do |mod|
  mod.public_instance_methods(false).each do |meth|
    (public_exposure_map[meth] ||= []) << mod.name
  end
end

# Step 3: Report violations — @api private methods that are still public.
errors = []

api_private_entries.each do |entry|
  exposing_modules = public_exposure_map[entry[:name]]
  next unless exposing_modules

  errors << "#{entry[:file]}:#{entry[:line]}  def #{entry[:name]}" \
            "  (annotated @api private but public in: #{exposing_modules.join(", ")})"
end

if errors.empty?
  puts "OK: all #{api_private_entries.size} @api private instance methods are non-public."
  exit 0
else
  warn "ERROR: #{errors.size} @api private instance method(s) are exposed as public:"
  errors.each { |e| warn "  #{e}" }
  exit 1
end
