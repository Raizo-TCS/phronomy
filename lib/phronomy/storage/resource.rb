# frozen_string_literal: true

module Phronomy
  module Storage
    # Immutable logical schema. Physical drivers receive a separate mapping.
    # @api public
    class Resource
      TYPES = [:string, :integer, :boolean, :nullable_string, :nullable_integer, :nullable_boolean].freeze
      attr_reader :id, :kind, :attributes, :immutable_attributes, :indexes, :unique, :guard

      # @api public
      def initialize(id:, kind:, attributes: {}, immutable_attributes: [], indexes: {}, unique: [], guard: nil)
        @id = Validation.key(id)
        @kind = kind
        @attributes = Validation.immutable(attributes)
        @immutable_attributes = Validation.immutable(immutable_attributes)
        @indexes = Validation.immutable(indexes)
        @unique = Validation.immutable(unique)
        @guard = Validation.immutable(guard)
        validate_shape!
        validate_indexes!
        validate_guard!
        validate_unique!
        freeze
      end

      # @api public
      def validate_attributes(values, partial: false)
        valid = values.is_a?(Hash) && (values.keys - attributes.keys).empty? && (partial || values.keys.sort == attributes.keys.sort)
        unless valid
          raise ArgumentError, "attributes do not match #{id}"
        end
        values = values.to_h do |name, value|
          type = attributes.fetch(name)
          if type.to_s.start_with?("nullable_") && value.nil?
            [name, nil]
          else
            [name, typed_value(name, type, value)]
          end
        end
        if guard && values.key?(guard[:via])
          values[guard[:via]] = Validation.key(values.fetch(guard[:via]))
        end
        Validation.attributes(values)
      end

      # @api public
      def index_values(index, equals)
        fields = indexes.fetch(index) { raise ArgumentError, "unknown index: #{index}" }
        raise ArgumentError, "index attributes must match exactly" unless equals.is_a?(Hash) && equals.keys.sort == fields.sort
        validate_attributes(equals, partial: true)
      end

      private

      def validate_shape!
        raise ArgumentError, "unsupported resource kind" unless [:records, :streams, :blobs].include?(kind)
        unless attributes.is_a?(Hash) && attributes.keys.all? { |key| key.is_a?(Symbol) } && attributes.values.all? { |type| TYPES.include?(type) }
          raise ArgumentError, "invalid attribute declarations"
        end
        unless field_list?(immutable_attributes, empty: true) && indexes.is_a?(Hash) && unique.is_a?(Array)
          raise ArgumentError, "invalid resource declarations"
        end
        if kind != :records && (!immutable_attributes.empty? || !indexes.empty? || !unique.empty?)
          raise ArgumentError, "only records declare indexes, uniqueness and immutable attributes"
        end
        raise ArgumentError, "streams have no indexed attributes" if kind == :streams && !attributes.empty?
      end

      def validate_indexes!
        unless indexes.all? { |name, fields| name.is_a?(Symbol) && field_list?(fields) }
          raise ArgumentError, "indexes need names and known distinct fields"
        end
      end

      def validate_unique!
        names = unique.map do |constraint|
          unless constraint.is_a?(Hash) && constraint.keys.sort == [:fields, :name, :where] &&
              constraint[:name].is_a?(Symbol) && field_list?(constraint[:fields])
            raise ArgumentError, "invalid unique constraint"
          end
          validate_attributes(constraint.fetch(:where), partial: true)
          constraint[:name]
        end
        raise ArgumentError, "unique constraints need distinct names" unless names.uniq == names
      end

      def validate_guard!
        return unless guard
        unless guard.is_a?(Hash) && guard.keys.sort == [:resource, :via] && guard[:resource].is_a?(String)
          raise ArgumentError, "invalid guard declaration"
        end
        Validation.key(guard[:resource])
        allowed = case kind
        when :records then [:key, *attributes.select { |_, type| type == :string }.keys]
        when :streams then [:stream]
        else []
        end
        raise ArgumentError, "invalid guard key" unless allowed.include?(guard[:via])
        if kind == :records && guard[:via] != :key && !immutable_attributes.include?(guard[:via])
          raise ArgumentError, "guard attributes must be immutable"
        end
      end

      def field_list?(values, empty: false)
        values.is_a?(Array) && (empty || !values.empty?) && values.uniq == values && (values - attributes.keys).empty?
      end

      def typed_value(name, type, value)
        valid = case type.to_s.delete_prefix("nullable_")
        when "string" then value.is_a?(String) && value.valid_encoding? && !value.include?("\0")
        when "integer" then value.is_a?(Integer)
        when "boolean" then value.equal?(true) || value.equal?(false)
        end
        raise ArgumentError, "invalid #{id}.#{name}" unless valid
        value.is_a?(String) ? value.encode(Encoding::UTF_8) : value
      end
    end
  end
end
