class UrlValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    unless value =~ /\A#{URI::DEFAULT_PARSER.make_regexp(['http', 'https'])}\z/
      record.errors.add(attribute, 'must be a valid URL')
    end
  end
end