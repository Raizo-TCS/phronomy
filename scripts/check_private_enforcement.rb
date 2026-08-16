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
# The check eager-loads Zeitwerk-managed code before examining visibility. It
# matches methods by source file and line, not only by method name, so a public
# method with the same name on another Phronomy class cannot create a false
# positive.
#
# Usage (run from the phronomy/ repository root):
#   bundle exec ruby scripts/check_private_enforcement.rb
#
# Exit codes:
#   0 — all @api private instance methods are non-public (or have no Ruby def)
#   1 — one or more @api private instance methods are exposed as public

require "bundler/setup"
require_relative "../lib/phronomy"

# `require "phronomy"` intentionally leaves most constants lazy. The old
# checker therefore missed @api private methods on files that had not happened
# to autoload. Eager loading is restricted to this CI/checker process and does
# not change Phronomy's production autoload policy.
Zeitwerk::Loader.eager_load_all

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

    rel_path = "lib/#{file.delete_prefix("#{lib_dir}/")}"
    api_private_entries << {
      name: m[1].to_sym,
      file: File.expand_path(file),
      rel_path: rel_path,
      line: j + 1
    }
  end
end

if api_private_entries.empty?
  puts "No @api private instance methods found."
  exit 0
end

# Step 2: Index public methods by their defining source location. Matching by
# source location is important because unrelated classes may legitimately have
# public and private methods with the same method name.
public_exposure_map = Hash.new { |hash, key| hash[key] = [] }
all_phronomy_modules = ObjectSpace.each_object(Module).select do |mod|
  mod.name&.start_with?("Phronomy")
end

all_phronomy_modules.each do |mod|
  mod.public_instance_methods(false).each do |meth|
    location = mod.instance_method(meth).source_location
    next unless location

    file, line = location
    public_exposure_map[[File.expand_path(file), line]] << "#{mod.name}##{meth}"
  rescue NameError
    # A method may disappear while reflecting over generated modules. Such a
    # method cannot be a stable public exposure for this check.
    next
  end
end

# Step 3: Report violations — an @api private declaration whose exact Ruby def
# is visible as a public instance method.
errors = []

api_private_entries.each do |entry|
  exposures = public_exposure_map[[entry[:file], entry[:line]]]
  next if exposures.empty?

  errors << "#{entry[:rel_path]}:#{entry[:line]}  def #{entry[:name]}" \
            "  (annotated @api private but public in: #{exposures.join(", ")})"
end

if errors.empty?
  puts "OK: all #{api_private_entries.size} @api private instance methods are non-public."
  exit 0
else
  warn "ERROR: #{errors.size} @api private instance method(s) are exposed as public:"
  errors.each { |e| warn "  #{e}" }
  exit 1
end
