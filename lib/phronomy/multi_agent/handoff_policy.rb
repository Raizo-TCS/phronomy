# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class HandoffPolicy
      CATEGORIES = %i[current_request history knowledge tool_exchanges].freeze
      MODES = %i[required forbidden selectable].freeze
      DEFAULTS = %i[include exclude].freeze

      Rule = Data.define(:category, :mode, :default) do
        def initialize(category:, mode:, default: nil)
          category = category.to_sym
          mode = mode.to_sym
          unless HandoffPolicy::CATEGORIES.include?(category)
            raise ArgumentError, "unknown Handoff policy category: #{category.inspect}"
          end
          unless HandoffPolicy::MODES.include?(mode)
            raise ArgumentError, "unknown Handoff policy mode: #{mode.inspect}"
          end
          if mode == :selectable
            default = (default || :exclude).to_sym
            unless HandoffPolicy::DEFAULTS.include?(default)
              raise ArgumentError, "selectable default must be :include or :exclude"
            end
          elsif default
            raise ArgumentError, "default is valid only for selectable Handoff rules"
          end
          super
          freeze
        end
      end

      class Builder
        def initialize
          @rules = {}
        end

        def required(category)
          set(category, :required)
        end

        def forbidden(category)
          set(category, :forbidden)
        end

        def selectable(category, default: :exclude)
          set(category, :selectable, default: default)
        end

        def build
          missing = CATEGORIES - @rules.keys
          unless missing.empty?
            raise ArgumentError,
              "HandoffPolicy must define all categories; missing: #{missing.inspect}"
          end
          HandoffPolicy.new(@rules.values)
        end

        private

        def set(category, mode, default: nil)
          category = category.to_sym
          if @rules.key?(category)
            raise ArgumentError, "Handoff policy category already defined: #{category.inspect}"
          end
          @rules[category] = Rule.new(category: category, mode: mode, default: default)
          self
        end
      end

      private_constant :Rule, :Builder

      def self.define(&block)
        raise ArgumentError, "HandoffPolicy.define requires a block" unless block
        builder = Builder.new
        builder.instance_eval(&block)
        builder.build
      end

      def self.default
        @default ||= define do
          required :current_request
          selectable :history, default: :include
          selectable :knowledge, default: :exclude
          selectable :tool_exchanges, default: :include
        end
      end

      def initialize(rules)
        @rules = Array(rules).to_h { |rule| [rule.category, rule] }.freeze
        missing = CATEGORIES - @rules.keys
        extra = @rules.keys - CATEGORIES
        unless missing.empty? && extra.empty?
          raise ArgumentError,
            "HandoffPolicy categories mismatch; missing=#{missing.inspect} extra=#{extra.inspect}"
        end
        freeze
      end

      def rule(category)
        @rules.fetch(category.to_sym)
      end

      def required?(category)
        rule(category).mode == :required
      end

      def forbidden?(category)
        rule(category).mode == :forbidden
      end

      def selectable?(category)
        rule(category).mode == :selectable
      end

      def default_include?(category)
        selected = rule(category)
        selected.mode == :required ||
          (selected.mode == :selectable && selected.default == :include)
      end

      def selectable_categories
        CATEGORIES.select { |category| selectable?(category) }.freeze
      end

      def to_h
        CATEGORIES.to_h do |category|
          selected = rule(category)
          [category.to_s, {
            "mode" => selected.mode.to_s,
            "default" => selected.default&.to_s
          }.compact]
        end.freeze
      end
    end
  end
end
