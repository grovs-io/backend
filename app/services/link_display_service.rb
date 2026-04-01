class LinkDisplayService
  class << self
    # Assembles link metadata hash (replaces set_generic_data_for_link instance var setting)
    # Returns { page_title:, page_subtitle:, page_image:, page_full_path:,
    #           domain:, tracking_campaign:, tracking_source:, tracking_medium:, tracking_data: }
    def generic_data_for_link(link)
      page_title = Grovs::Links::DEFAULT_TITLE
      if link.title.present?
        page_title = link.title
      elsif link.domain.generic_title.present?
        page_title = link.domain.generic_title
      end

      page_subtitle = Grovs::Links::DEFAULT_SUBTITLE
      if link.subtitle.present?
        page_subtitle = link.subtitle
      elsif link.domain.generic_subtitle.present?
        page_subtitle = link.domain.generic_subtitle
      end

      page_image = Grovs::Links::SOCIAL_PREVIEW
      if link.image_resource
        page_image = link.image_resource
      elsif link.domain.image_url.present?
        page_image = link.domain.image_url
      end

      tracking_campaign = link.tracking_campaign
      tracking_source = link.tracking_source
      tracking_medium = link.tracking_medium

      {
        page_title: page_title,
        page_subtitle: page_subtitle,
        page_image: page_image,
        page_full_path: link.access_path,
        domain: "https://#{link.domain.full_domain}",
        tracking_campaign: tracking_campaign,
        tracking_source: tracking_source,
        tracking_medium: tracking_medium,
        tracking_data: {
          utm_source: tracking_source,
          utm_medium: tracking_medium,
          utm_campaign: tracking_campaign
        }.compact
      }
    end

    # Whether to log a VIEW event
    def should_log_view?(go_to_fallback, device, grovs_redirect)
      should_log = [nil, false].include?(go_to_fallback)
      should_log &&= !device.bot?
      should_log &&= grovs_redirect.nil?
      should_log
    end

    # Resolves appstore/fallback URL from platform config hash
    # Returns URL string or nil
    def fallback_url(config)
      config = config[:phone] || config[:tablet]
      return nil unless config

      if config["appstore"] != nil
        return config["appstore"]
      end

      if config["fallback"]
        return config["fallback"]
      end

      nil
    end
  end
end
