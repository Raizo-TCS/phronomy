# frozen_string_literal: true

module Phronomy
  module Filter
    # Abstract base class for value filters.
    #
    # A filter may either transform a value (return the new value) or block it
    # (raise {Phronomy::FilterBlockError}).  The same filter instance can be
    # registered at multiple call sites — input, output, and tool result.
    #
    # @example PII masking filter
    #   class PiiMaskFilter < Phronomy::Filter::Base
    #     def call(value, **_context)
    #       value.to_s
    #            .gsub(/\b\d{2,4}-\d{2,4}-\d{4}\b/, "[PHONE]")
    #            .gsub(/\b(?:\d{4}[- ]?){3}\d{4}\b/, "[CARD]")
    #     end
    #   end
    #
    # @example Blocking filter
    #   class NoBadWordFilter < Phronomy::Filter::Base
    #     def call(value, **_context)
    #       block!("Forbidden content detected") if value.to_s.include?("badword")
    #       value
    #     end
    #   end
    #
    # @api public
    class Base
      # Process +value+ and return the (possibly transformed) result.
      #
      # The +context+ keyword arguments vary by call site:
      #   - Tool result: +{ tool_name: String, args: Hash }+
      #   - Input / output: +(empty)+
      #
      # @param value   [Object] the value being filtered
      # @param context [Hash]   optional call-site metadata
      # @return [Object] the transformed value (or the original if unchanged)
      # @raise [Phronomy::FilterBlockError] to reject the value
      # @api public
      def call(value, **_context)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      protected

      # Reject the value with a human-readable reason.
      # @param reason [String]
      # @raise [Phronomy::FilterBlockError]
      # @api public
      def block!(reason)
        raise Phronomy::FilterBlockError.new(reason, filter: self)
      end
    end
  end
end
