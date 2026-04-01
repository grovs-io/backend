module AssetService
  def self.permanent_url(asset)
    if asset.attached?
      url = ENV["S3_ASSET_PREFIX"] + Rails.application.routes.url_helpers.rails_blob_path(asset, only_path: true)
      return url
    end

    nil
  end
end
