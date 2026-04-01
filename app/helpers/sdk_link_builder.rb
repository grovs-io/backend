module SdkLinkBuilder

  private

  def build_and_save_sdk_link(platform_name:, visitor: nil, image_url: nil, image: nil)
    domain = @project.domain_for_project
    redirect_config = @project.redirect_config

    path = LinksService.generate_valid_path(domain)

    link = Link.new
    link.generated_from_platform = platform_name
    link.title = title_param
    link.subtitle = subtitle_param
    link.path = path
    link.domain = domain
    link.redirect_config = redirect_config
    link.sdk_generated = true
    link.image_url = image_url
    link.visitor = visitor

    # Tracking
    link.tracking_campaign = tracking_campaign_param
    link.tracking_source = tracking_source_param
    link.tracking_medium = tracking_medium_param

    if data_param
      link.data = JSON.parse(data_param)
    end

    if image
      link.image.attach(image)
    end

    if tags_param
      link.tags = JSON.parse(tags_param)
    end

    unless show_preview_param.nil?
      link.show_preview_ios = show_preview_param
      link.show_preview_android = show_preview_param
    end

    unless show_preview_ios_param.nil?
      link.show_preview_ios = show_preview_ios_param
    end

    unless show_preview_android_param.nil?
      link.show_preview_android = show_preview_android_param
    end

    link.save!

    # Update custom redirects
    update_custom_redirects_for_link(link)

    link
  end
end
