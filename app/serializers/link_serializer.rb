class LinkSerializer < BaseSerializer
  attributes :id, :name, :path, :title, :subtitle, :active,
             :sdk_generated, :data, :tags, :updated_at,
             :show_preview_ios, :show_preview_android,
             :ads_platform, :generated_from_platform,
             :tracking_source, :tracking_medium, :tracking_campaign,
             :visitor_id, :campaign_id


  def build(slim: false, **)
    h = super()
    unless slim
      h["image"] = record.image_resource
      h["access_path"] = record.access_path
      h["ios_custom_redirect"] = CustomRedirectSerializer.serialize(record.ios_custom_redirect)
      h["android_custom_redirect"] = CustomRedirectSerializer.serialize(record.android_custom_redirect)
      h["desktop_custom_redirect"] = CustomRedirectSerializer.serialize(record.desktop_custom_redirect)
    end
    h
  end
end
