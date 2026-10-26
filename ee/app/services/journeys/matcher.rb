require "bigdecimal"

# Event property filters, read as a device reads an in-app trigger's (ee/config/in_app/README.md, "Rules the cases pin down").
module Journeys::Matcher
  NUMBER = /\A-?\d+(\.\d+)?\z/

  module_function

  def pass?(filters, properties) = Array(filters).all? { |f| compare(properties[f["field"]], f["op"], f["value"]) }

  def compare(actual, operator, expected)
    actual = text(actual)
    present = !actual.nil? && actual != ""
    return !present if operator == "is_not_set"
    return false unless present
    return true if operator == "is_set"
    return between?(actual, expected) if operator == "between"

    expected = text(expected)
    return false if expected.nil?

    case operator
    when "eq" then same?(actual, expected)
    when "neq" then !same?(actual, expected)
    when "gt" then numbers?(actual, expected) && Float(actual) > Float(expected)
    when "lt" then numbers?(actual, expected) && Float(actual) < Float(expected)
    when "contains" then actual.downcase.include?(expected.downcase)
    when "not_contains" then !actual.downcase.include?(expected.downcase)
    else false
    end
  end

  def text(value)
    case value
    when nil, Hash, Array then nil
    when Float then value == value.floor ? value.to_i.to_s : BigDecimal(value.to_s).to_s("F")
    else value.to_s
    end
  end

  def between?(actual, range)
    return false unless range.is_a?(Array) && range.size == 2 && numbers?(actual, *range.map { |v| text(v) })

    Float(actual).between?(Float(text(range[0])), Float(text(range[1])))
  end

  def numbers?(*values) = values.all? { |v| v.to_s.match?(NUMBER) }

  def same?(actual, expected)
    return (Float(actual) <=> Float(expected)).zero? if numbers?(actual, expected)

    actual.downcase == expected.downcase
  end
end
