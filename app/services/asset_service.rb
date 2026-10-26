module AssetService
  def self.permanent_url(asset)
    if asset.is_a?(ActiveStorage::Blob) || asset.attached?
      url = ENV.fetch("S3_ASSET_PREFIX", "") + path(asset)
      return url
    end

    nil
  end

  def self.path(asset) = Rails.application.routes.url_helpers.rails_blob_path(asset, only_path: true)

  # The signed id is in every address form (any host, redirect or proxy), and raw strings keep "&" unescaped.
  def self.names?(value, blob) = contains?(value, blob.signed_id)

  def self.contains?(value, id)
    case value
    when Hash then value.values.any? { |v| contains?(v, id) }
    when Array then value.any? { |v| contains?(v, id) }
    else value.is_a?(String) && value.include?(id)
    end
  end

  private_class_method :contains?

  # Copies keep their filename, so swapping the signed id alone repoints every address form untouched.
  def self.swap(value, from, to)
    case value
    when Hash then value.transform_values { |v| swap(v, from, to) }
    when Array then value.map { |v| swap(v, from, to) }
    when String then value.gsub(from.signed_id, to.signed_id)
    else value
    end
  end

  # permanent_url is a bare path once S3_ASSET_PREFIX is unset (common self-hosted); html needs an absolute https address.
  def self.absolute_url(asset)
    url = permanent_url(asset)
    return url if url.nil? || ENV["S3_ASSET_PREFIX"].present?

    "#{ENV['SERVER_HOST_PROTOCOL']}api.#{ENV['SERVER_HOST']}#{url}"
  end
end
