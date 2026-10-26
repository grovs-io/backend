module SmartBannerLinkData
  class Invalid < StandardError; end

  PAGE_PATH_KEY = "page_path".freeze
  MAX_PAGE_PATH_LENGTH = 512
  MAX_KEYS = 20
  MAX_KEY_LENGTH = 64
  MAX_VALUE_LENGTH = 512
  MAX_BYTES = 4096

  module_function

  def build(page_path:, data:)
    unless page_path.is_a?(String) && page_path.start_with?("/") && page_path.length <= MAX_PAGE_PATH_LENGTH
      raise Invalid, "page_path must start with / and be at most #{MAX_PAGE_PATH_LENGTH} characters"
    end

    canonical = { PAGE_PATH_KEY => page_path }.merge(validated_data(data)).sort.to_h
    raise Invalid, "link data must be at most #{MAX_BYTES} bytes" if JSON.generate(canonical).bytesize > MAX_BYTES

    canonical
  end

  def digest(canonical)
    Digest::SHA256.hexdigest(JSON.generate(canonical))
  end

  def validated_data(data)
    return {} if data.nil?
    raise Invalid, "data must be an object" unless data.is_a?(Hash)

    data = data.to_h.transform_keys(&:to_s).compact
    raise Invalid, "data can have at most #{MAX_KEYS} keys" if data.size > MAX_KEYS

    data.each do |key, value|
      raise Invalid, "data keys must be at most #{MAX_KEY_LENGTH} characters" if key.length > MAX_KEY_LENGTH
      next if value == true || value == false || (value.is_a?(Numeric) && value.to_f.finite?)
      raise Invalid, "data values must be strings, finite numbers or booleans" unless value.is_a?(String)
      raise Invalid, "data values must be at most #{MAX_VALUE_LENGTH} characters" if value.length > MAX_VALUE_LENGTH
    end

    data
  end
end
