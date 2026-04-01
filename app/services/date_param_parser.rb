class DateParamParser
  def self.call(value, default:)
    return default unless value.present?
    Date.parse(value)
  rescue ArgumentError
    default
  end
end
