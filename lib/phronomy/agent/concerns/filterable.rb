# frozen_string_literal: true

module Phronomy
  module Agent
    module Concerns
      # Adds input, output, and tool-result filter support to an agent.
      #
      # Filters transform (or block) values at three call sites:
      #   - *input*       — the raw user input string, before the LLM is called
      #   - *output*      — the final LLM output string, before it is returned
      #   - *tool result* — the return value of each tool call
      #
      # Filters run after legacy {Phronomy::Guardrail} checks (which only block).
      # Each filter in the chain receives the value returned by the previous one.
      # A {Phronomy::FilterBlockError} raised inside any filter propagates to the
      # caller.
      #
      # @api private
      module Filterable
        def self.included(base)
          base.extend(ClassMethods)
        end

        # Class-level DSL mixed into the including agent class.
        module ClassMethods
          # Registers a filter applied to every invocation's user input.
          # @param filter [Phronomy::Filter::Base]
          # @return [void]
          # @api public
          def input_filter(filter)
            @_class_input_filters ||= []
            @_class_input_filters << filter
          end

          # Registers a filter applied to every invocation's final LLM output.
          # @param filter [Phronomy::Filter::Base]
          # @return [void]
          # @api public
          def output_filter(filter)
            @_class_output_filters ||= []
            @_class_output_filters << filter
          end

          # Registers a filter applied to every tool result for all tools.
          # @param filter [Phronomy::Filter::Base]
          # @return [void]
          # @api public
          def tool_result_filter(filter)
            @_class_tool_result_filters ||= []
            @_class_tool_result_filters << filter
          end

          # @return [Array<Phronomy::Filter::Base>]
          # @api private
          def _class_input_filters
            @_class_input_filters || []
          end

          # @return [Array<Phronomy::Filter::Base>]
          # @api private
          def _class_output_filters
            @_class_output_filters || []
          end

          # @return [Array<Phronomy::Filter::Base>]
          # @api private
          def _class_tool_result_filters
            @_class_tool_result_filters || []
          end
        end

        # Registers an input filter on this instance.
        # Runs in addition to any class-level input filters.
        # @param filter [Phronomy::Filter::Base]
        # @return [self]
        # @api public
        def add_input_filter(filter)
          @_instance_input_filters ||= []
          @_instance_input_filters << filter
          self
        end

        # Registers an output filter on this instance.
        # Runs in addition to any class-level output filters.
        # @param filter [Phronomy::Filter::Base]
        # @return [self]
        # @api public
        def add_output_filter(filter)
          @_instance_output_filters ||= []
          @_instance_output_filters << filter
          self
        end

        # Registers a tool result filter on this instance.
        #
        # When called with two arguments, the filter is scoped to the given tool
        # class only.  When called with one argument, it applies to all tools.
        #
        # @overload add_tool_result_filter(filter)
        #   @param filter [Phronomy::Filter::Base] applied to every tool
        # @overload add_tool_result_filter(tool_class, filter)
        #   @param tool_class [Class] scope the filter to this tool
        #   @param filter [Phronomy::Filter::Base]
        # @return [self]
        # @api public
        def add_tool_result_filter(tool_class_or_filter, filter = nil)
          if filter.nil?
            # Single-argument form: apply to all tools.
            @_instance_tool_result_filters ||= []
            @_instance_tool_result_filters << tool_class_or_filter
          else
            # Two-argument form: scoped to one tool class.
            @_scoped_tool_result_filters ||= {}
            (@_scoped_tool_result_filters[tool_class_or_filter] ||= []) << filter
          end
          self
        end

        private

        # Run input filters (guardrails first, then class-level, then instance-level).
        # Guardrails registered via +add_input_guardrail+ implement the Filter::Base
        # interface via +Guardrail::Base#call+ and are included at the front of the chain.
        # @param input [String, Hash] the raw user input
        # @return [String, Hash] the (possibly transformed) input
        # @api private
        def run_input_filters!(input)
          guardrails = @input_guardrails || []
          class_filters = self.class._class_input_filters
          inst_filters = @_instance_input_filters || []
          (guardrails + class_filters + inst_filters).inject(input) { |val, f| f.call(val) }
        end

        # Run output filters (guardrails first, then class-level, then instance-level).
        # Guardrails registered via +add_output_guardrail+ implement the Filter::Base
        # interface via +Guardrail::Base#call+ and are included at the front of the chain.
        # @param output [String] the LLM output
        # @return [String] the (possibly transformed) output
        # @api private
        def run_output_filters!(output)
          guardrails = @output_guardrails || []
          class_filters = self.class._class_output_filters
          inst_filters = @_instance_output_filters || []
          (guardrails + class_filters + inst_filters).inject(output) { |val, f| f.call(val) }
        end

        # Collect all tool-result filters (global + scoped) for a given tool class.
        # @param tool_class [Class]
        # @return [Array<Phronomy::Filter::Base>]
        # @api private
        def _tool_result_filters_for(tool_class)
          global = self.class._class_tool_result_filters + (@_instance_tool_result_filters || [])
          scoped = (@_scoped_tool_result_filters || {})[tool_class] || []
          global + scoped
        end
      end
    end
  end
end
