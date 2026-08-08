# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Knowledge
        # Abstract base class for all KnowledgeSource implementations.
        class Base
          # @api public
          def fetch(query: nil, cancellation_token: nil)
            cancellation_token&.raise_if_cancelled!
            raise NotImplementedError, "#{self.class}#fetch is not implemented"
          end

          # @api public
          def fetch_async(query: nil, cancellation_token: nil, timeout: nil)
            Phronomy::Runtime.instance.blocking_io.submit(
              timeout: timeout,
              cancellation_token: cancellation_token
            ) do
              fetch(query: query, cancellation_token: cancellation_token)
            end
          end

          # Returns whether this source is logically static across invocations.
          # @api public
          def static?
            false
          end
        end
      end
    end
  end
end
