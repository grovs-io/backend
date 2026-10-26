# Which fields MCP may read values of or group by: no built-in identifiers, no identity-looking properties.
module McpIdentityPolicy
  IDENTITY_FIELDS = %w[visitor visitor_id session_id sdk_identifier device_id].freeze
  # Shared with the MCP server (backend-enums.json); matched against the snake_cased key, see normalize.
  IDENTITY_PROPERTY_CORE = '(?!(?:is|has)_)(?:(?:.*_)?(?:e?mail(?:_address)?|phone(?:_number)?|mobile_(?:number|phone)|address|' \
                           'ip(?:_addr(?:ess)?)?|(?:user|customer|member|account|person|visitor|device|profile|client|player|' \
                           'subscriber|contact|session|anonymous|advertising|install|external|distinct|sdk)_?id|(?:sdk_)?identifier)|' \
                           '(?:first|last|full|user|display|customer|contact)?_?name|username|adid|idfa|idfv|gaid)'
  IDENTITY_PROPERTY = /\A(?:#{IDENTITY_PROPERTY_CORE})\z/

  module_function

  # builtin: the caller's own allowlist; those are judged by IDENTITY_FIELDS, never by the property pattern.
  def blocked?(field, builtin:)
    f = field.to_s
    return IDENTITY_FIELDS.include?(f) if builtin.include?(f)
    return true if f.start_with?("user.")
    return false if f.start_with?("purchase.")

    identity_property?(f.delete_prefix("properties."))
  end

  def identity_property?(key)
    normalize(key).match?(IDENTITY_PROPERTY)
  end

  # customerEmail, customer-email and user.email all become customer_email / user_email.
  def normalize(key)
    key.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').tr("-. ", "___").downcase
  end
end
