#!/usr/bin/env ruby
# frozen_string_literal: true

# Explicit one-time conversion of a pre-structured-output Result JSON object.
# Never infer old formats in the runtime reader; never overwrite the source.
require_relative "../lib/phronomy"

abort "Usage: ruby scripts/migrate_generator_verifier_result.rb OLD.json NEW.json" unless ARGV.length == 2
source, destination = ARGV
value = JSON.parse(File.read(source), allow_duplicate_key: false, allow_nan: false,
  allow_comments: false, allow_invalid_escape: false, allow_control_characters: false)
abort "Expected an old Result object without failure" unless value.is_a?(Hash) && !value.key?("failure")
value["failure"] = nil
result = Phronomy::GeneratorVerifier::Result.from_h(value)
File.open(destination, File::WRONLY | File::CREAT | File::EXCL) do |file|
  file.write(JSON.pretty_generate(result.to_h))
  file.write("\n")
end
