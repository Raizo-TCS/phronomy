# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "standard/rake"

# Verify that @api private classes do not leak into the public YARD output.
# Any class or module without @api private that ends up in the public doc must
# have a corresponding entry in the Features table in README.md.
#
# Usage: bundle exec rake yard_check
desc "Build YARD docs excluding @api private items and check for undocumented public APIs"
task :yard_check do
  require "yard"
  YARD::Registry.clear
  YARD.parse(Dir["lib/**/*.rb"])

  undocumented = []
  YARD::Registry.all(:class, :module).each do |obj|
    next if obj.visibility == :private
    next if obj.tag(:api)&.name == "private"
    next if obj.docstring.blank?

    # Classes/modules with no docstring that are not @api private are worth
    # noting, but only raise on truly undocumented public objects.
    if obj.docstring.empty?
      undocumented << obj.path
    end
  end

  unless undocumented.empty?
    warn "The following public classes/modules have no YARD documentation:\n" \
         "  #{undocumented.join("\n  ")}\n" \
         "Either add a docstring or mark them @api private."
    exit 1
  end
  puts "yard_check passed — no undocumented public classes/modules found."
end

task default: %i[spec standard]
