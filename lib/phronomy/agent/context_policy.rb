# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextPolicy
      def call(_request)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      def descriptor
        raise NotImplementedError, "#{self.class}#descriptor is not implemented"
      end
    end
  end
end
