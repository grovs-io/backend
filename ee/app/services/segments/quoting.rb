module Segments
  module Quoting
    extend Analytics::QueryHelpers

    STRING_OPS = %w[is is_not contains].freeze
    MAX_VALUES = Analytics::QueryHelpers::MAX_FILTER_VALUES
    MAX_BYTES = 256

    def self.literal(value) = "'#{sanitize_string(value)}'"

    def self.string_clause(column_sql, op, values) # rubocop:disable Naming/MethodParameterName
      list = Array(values)
      case op
      when "is" then "#{column_sql} IN (#{list.map { |v| literal(v) }.join(', ')})"
      when "is_not" then "#{column_sql} NOT IN (#{list.map { |v| literal(v) }.join(', ')})"
      when "contains"
        clauses = list.map { |v| "lower(#{column_sql}) LIKE '%#{sanitize_like(v.to_s.downcase)}%'" }
        list.size == 1 ? clauses.first : "(#{clauses.join(' OR ')})"
      else raise ArgumentError, "unknown string op #{op}"
      end
    end

    def self.clean_values(value, path:, errors:)
      unless scalar_shape?(value)
        errors << { path: path, message: "value must be 1-#{MAX_VALUES} non-empty strings of at most #{MAX_BYTES} bytes" }
        return nil
      end
      raw_list = Array(value).map(&:to_s)
      if raw_list.empty? || raw_list.size > MAX_VALUES || raw_list.any? { |v| v.empty? || v.bytesize > MAX_BYTES }
        errors << { path: path, message: "value must be 1-#{MAX_VALUES} non-empty strings of at most #{MAX_BYTES} bytes" }
        return nil
      end
      raw_list.uniq.sort
    end

    def self.scalar_shape?(value)
      case value
      when String, Numeric, TrueClass, FalseClass then true
      when Array then value.all? { |v| v.is_a?(String) || v.is_a?(Numeric) || v.is_a?(TrueClass) || v.is_a?(FalseClass) }
      else false
      end
    end

    def self.strict_int(value)
      case value
      when Integer then value
      when String then value.match?(/\A\d+\z/) ? value.to_i : nil
      end
    end

    def self.strict_bool(value)
      case value
      when TrueClass, FalseClass then value
      when "true" then true
      when "false" then false
      end
    end

    def self.strict_flag(raw, key, path, errors)
      return false unless raw.key?(key)

      value = strict_bool(raw[key])
      errors << { path: "#{path}.#{key}", message: "#{key} must be true or false" } if value.nil?
      value || false
    end
  end
end
