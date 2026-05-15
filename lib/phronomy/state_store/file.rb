# frozen_string_literal: true

require "fileutils"
require "json"

module Phronomy
  module StateStore
    # File-system-backed state store.
    # Persists graph state as a JSON file under a configurable directory.
    # No additional server or database migration is required — it works with
    # the local file system out of the box.
    #
    # Each thread_id is stored as a separate file named "<thread_id>.json".
    # The thread_id is sanitised before use as a filename to prevent path
    # traversal: only alphanumeric characters, hyphens, underscores, and dots
    # are allowed; all other characters are replaced with underscores.
    #
    # @note This store is suitable for single-process use (development, CLI
    #   tools, tests).  It is not safe for concurrent access across multiple
    #   processes without external locking.
    #
    # @example
    #   store = Phronomy::StateStore::File.new(dir: "tmp/workflow_states")
    #   Phronomy::Workflow.define(MyContext, state_store: store) do
    #     # ...
    #   end
    class File < Base
      # @param dir [String] directory where state files are stored.
      #   Created automatically if it does not exist.
      def initialize(dir: ::File.join(::Dir.tmpdir, "phronomy_states"))
        @dir = ::File.expand_path(dir)
        ::FileUtils.mkdir_p(@dir)
      end

      # @param state [Object] includes Phronomy::WorkflowContext; must have a non-nil thread_id
      # @return [self]
      def save(state)
        ::File.write(path(state.thread_id), serialize_state(state))
        self
      end

      # @param thread_id [String]
      # @return [Object, nil] state instance or nil if not found
      def load(thread_id)
        file = path(thread_id)
        return nil unless ::File.exist?(file)

        deserialize_state(::File.read(file))
      end

      # Removes the saved state file for the given thread_id.
      # @param thread_id [String]
      # @return [self]
      def clear(thread_id)
        file = path(thread_id)
        ::File.delete(file) if ::File.exist?(file)
        self
      end

      # Removes all state files managed by this store instance.
      # @return [self]
      def clear_all
        ::Dir.glob(::File.join(@dir, "*.json")).each { |f| ::File.delete(f) }
        self
      end

      # @return [String] the directory used by this store
      def directory
        @dir
      end

      private

      # Converts a thread_id into a safe filename component.
      # Characters outside [A-Za-z0-9._-] are replaced with underscores.
      def sanitize(thread_id)
        thread_id.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
      end

      def path(thread_id)
        ::File.join(@dir, "#{sanitize(thread_id)}.json")
      end
    end
  end
end
