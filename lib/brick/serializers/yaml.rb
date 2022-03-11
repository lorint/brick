# frozen_string_literal: true

require 'yaml'

module Brick
  module Serializers
    # The default serializer for, e.g. `versions.object`.
    module YAML
      extend self # makes all instance methods become module methods as well

      def load(string)
        ::YAML.safe_load string
      end

      def dump(object)
        ::YAML.dump object
      end

      # Returns a SQL LIKE condition to be used to match the given field and
      # value in the serialized object.
      def where_object_condition(arel_field, field, value)
        arel_field.matches("%\n#{field}: #{value}\n%")
      end
    end
  end
end
