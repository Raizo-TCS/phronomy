# frozen_string_literal: true

require "spec_helper"
require "json"

# ---------------------------------------------------------------------------
# Public API Compatibility Gate (Issue #210)
#
# Loads the stored API snapshot from spec/fixtures/api_snapshot.json and
# verifies that every method recorded in the snapshot still exists on its
# corresponding class/module.
#
# Purpose:
#   Detect *unintentional* API removals or renames before they land in a
#   release.  Adding new methods is always allowed; removing or renaming a
#   documented public API method will cause this spec to fail.
#
# Updating the snapshot:
#   When an intentional API change is made (e.g. removing a deprecated method
#   or promoting a new one), regenerate the snapshot:
#     bundle exec ruby scripts/api_snapshot.rb --write
#   Commit the updated spec/fixtures/api_snapshot.json together with the
#   code change.
# ---------------------------------------------------------------------------

API_SNAPSHOT_PATH = File.expand_path("../fixtures/api_snapshot.json", __dir__).freeze

RSpec.describe "Public API compatibility gate (Issue #210)" do
  let(:snapshot) { JSON.parse(File.read(API_SNAPSHOT_PATH)) }

  it "snapshot file exists" do
    expect(File).to exist(API_SNAPSHOT_PATH)
  end

  it "snapshot contains at least one entry" do
    expect(snapshot).not_to be_empty
  end

  # For each entry in the snapshot, verify the class/module still exists and
  # every recorded method is still present.
  describe "per-class method presence" do
    # Load the snapshot once at describe-time so we can generate one example
    # per class (helpful for readable failure output).
    snapshot_data = JSON.parse(File.read(API_SNAPSHOT_PATH))

    snapshot_data.each do |entry|
      class_name = entry["name"]
      instance_methods = entry["public_instance_methods"] || []
      class_methods = entry["public_class_methods"] || []

      context class_name do
        let(:klass) do
          # Resolve the constant by name so the spec stays in sync with the
          # codebase without hardcoding the list here.
          Object.const_get(class_name)
        rescue NameError => e
          raise "Snapshot refers to #{class_name} but it no longer exists: #{e.message}"
        end

        it "still exists as a constant" do
          expect(Object.const_defined?(class_name)).to be true
        end

        unless instance_methods.empty?
          it "has all snapshotted public instance methods" do
            current = klass.public_instance_methods
            missing = instance_methods.reject { |m| current.include?(m.to_sym) }
            expect(missing).to be_empty,
              "#{class_name} is missing public instance methods that were in the snapshot:\n" \
              "  #{missing.join(", ")}\n" \
              "If this is intentional, regenerate the snapshot:\n" \
              "  bundle exec ruby scripts/api_snapshot.rb --write"
          end
        end

        unless class_methods.empty?
          it "has all snapshotted public class methods" do
            current = klass.public_methods
            missing = class_methods.reject { |m| current.include?(m.to_sym) }
            expect(missing).to be_empty,
              "#{class_name} is missing public class methods that were in the snapshot:\n" \
              "  #{missing.join(", ")}\n" \
              "If this is intentional, regenerate the snapshot:\n" \
              "  bundle exec ruby scripts/api_snapshot.rb --write"
          end
        end
      end
    end
  end
end
