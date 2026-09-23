#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../lib/phronomy"

# Explicit SPI 2 scope, independent of the Stable/Beta product API snapshot.
# Private dispatch and domain composition helpers are deliberately excluded.
surfaces = {
  Phronomy::Persistence => Phronomy::Persistence.public_instance_methods(false).sort,
  Phronomy::Storage::Backend => %i[initialize capabilities transaction resources view],
  Phronomy::Storage::Backends::InMemory => %i[initialize capabilities],
  Phronomy::Storage::View => %i[records streams blobs check!],
  Phronomy::Storage::Resource => %i[initialize id kind attributes immutable_attributes indexes unique guard validate_attributes index_values],
  Phronomy::Storage::Records => %i[resource insert read fetch replace delete scan delete_matching],
  Phronomy::Storage::Streams => %i[resource append read head delete],
  Phronomy::Storage::Blobs => %i[resource put_if_absent fetch exist?],
  Phronomy::Storage::GuardRef => %i[initialize resource key],
  Phronomy::Storage::Condition::RevisionIs => %i[initialize resource key expected],
  Phronomy::Storage::Condition::StreamHeadIs => %i[initialize resource stream expected],
  Phronomy::Storage::Condition::NoRows => %i[initialize resource index equals],
  Phronomy::Storage::Entry::Record => %i[initialize key revision attributes record],
  Phronomy::Storage::Entry::Stream => %i[initialize position id record],
  Phronomy::Storage::Entry::Append => %i[initialize id record],
  Phronomy::Storage::Entry::Blob => %i[initialize key bytes attributes],
  Phronomy::Storage::UniqueConstraintError => %i[initialize resource constraint],
  Phronomy::Storage::ConditionFailedError => %i[initialize condition]
}
snapshot = {spi_version: 2, capabilities: Phronomy::Storage::Backend::REQUIRED_CAPABILITIES,
            surfaces: surfaces.to_h { |type, names| [type.name, names.sort.to_h { |name| [name, type.instance_method(name).parameters] }] }}
json = JSON.pretty_generate(snapshot) + "\n"
if ARGV.include?("--write")
  File.write(File.expand_path("../spec/fixtures/storage_spi_v2_snapshot.json", __dir__), json)
else
  puts json
end
