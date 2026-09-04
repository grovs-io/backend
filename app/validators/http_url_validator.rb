# Named apart from validate_url's UrlValidator (openid_connect dependency), which shadows it.
class HttpUrlValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    unless value =~ /\A#{URI::DEFAULT_PARSER.make_regexp(['http', 'https'])}\z/
      record.errors.add(attribute, 'must be a valid URL')
    end
  end
end