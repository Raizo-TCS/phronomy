# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    # Generation defines the information it needs. Agent owns schema validation.
    # @api private
    module Protocol
      DEFAULT_CITATION = Phronomy::Values::Immutable.json({
        type: "object", properties: {source: {type: "string"}, excerpt: {type: "string"}},
        required: %w[source excerpt], additionalProperties: false
      })
      REVIEW = Phronomy::Values::Immutable.json({
        type: "object", properties: {approved: {type: "boolean"}, score: {type: "number", minimum: 0, maximum: 1},
                                     feedback: {type: "string"}},
        required: %w[approved score feedback], additionalProperties: false
      })

      module_function

      def draft(citation_schema)
        citation = Phronomy::Values::Immutable.json(citation_schema)
        unless citation.is_a?(Hash) && citation["type"] == "object"
          raise ArgumentError, "citation_schema must declare an object"
        end
        Phronomy::Values::Immutable.json({
          type: "object", properties: {answer: {type: "string"}, confidence: {type: "number", minimum: 0, maximum: 1},
                                       citations: {type: "array", items: embed_citation(citation)}},
          required: %w[answer confidence citations], additionalProperties: false
        })
      end

      # A local citation reference is relative to the citation document. Rebase
      # only schema positions when embedding it, leaving const/enum data intact.
      def embed_citation(node)
        return node unless node.is_a?(Hash)
        node.to_h do |key, value|
          transformed = case key
          when "$ref"
            (value.is_a?(String) && value.start_with?("#")) ? "#/properties/citations/items#{value.delete_prefix("#")}" : value
          when "properties", "$defs"
            value.is_a?(Hash) ? value.transform_values { |child| embed_citation(child) } : value
          when "items", "additionalProperties"
            embed_citation(value)
          when "anyOf"
            value.is_a?(Array) ? value.map { |child| embed_citation(child) } : value
          else
            value
          end
          [key, transformed]
        end
      end
      private_class_method :embed_citation
    end
  end
end
