# frozen_string_literal: true

module Phronomy
  module Agent
    # Detached Agent outcome records and content, prepared before backend writes.
    # This is a content-only overlay, not a transaction or a replayable callback.
    # @api private
    class OutcomeWritePlan
      class Contents < Phronomy::ContentStore::Base
        attr_reader :writes

        def initialize(contents, write_class:)
          @contents, @write_class = contents, write_class
          @values, @writes = {}, []
        end

        def put(bytes, canonicalization_version:)
          value = String(bytes).b.dup.freeze
          version = Integer(canonicalization_version)
          reference = content_id_for(value).freeze
          @values[reference] = value
          @writes << @write_class.new(reference: reference, bytes: value, canonicalization_version: version)
          reference
        end

        def fetch(reference) = (@values[reference] || @contents.fetch(reference)).dup
        def exist?(reference) = @values.key?(reference) || @contents.exist?(reference)
      end

      ContentView = Data.define(:contents)
      attr_reader :outcome, :writes

      def initialize(outcome:, writes:)
        @outcome, @writes = outcome, writes.dup.freeze
        freeze
      end

      def after(before:, state_data:, participation:)
        Phronomy::Values::Immutable.copy([
          [outcome.root.to_h, outcome.execution.to_h, outcome.appended_records.map(&:to_h),
            state_data, before.fetch(0).fetch(4)],
          participation
        ])
      end
    end
  end
end
