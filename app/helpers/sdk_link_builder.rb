module SdkLinkBuilder

  private

  def build_and_save_sdk_link(platform_name:, visitor: nil, image_url: nil, image: nil)
    link = SdkLinkCreationService.create(
      project: @project, platform: platform_name, visitor: visitor,
      title: title_param, subtitle: subtitle_param, image_url: image_url, image: image,
      data: data_param && JSON.parse(data_param), tags: tags_param && SmartBanner.without_reserved_tags(JSON.parse(tags_param)),
      show_preview_ios: show_preview_ios_param.nil? ? show_preview_param : show_preview_ios_param,
      show_preview_android: show_preview_android_param.nil? ? show_preview_param : show_preview_android_param,
      copy_to_clipboard_ios: copy_to_clipboard_ios_param, copy_to_clipboard_android: copy_to_clipboard_android_param,
      tracking_campaign: tracking_campaign_param, tracking_source: tracking_source_param,
      tracking_medium: tracking_medium_param
    )

    update_custom_redirects_for_link(link)

    link
  end
end
