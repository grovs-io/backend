module WebConfigurationService::ConfigHelpers
  extend ActiveSupport::Concern

  private

  def generic_config(link, phone_redirect, tablet_redirect)
    unless validate_link(link)
      return nil
    end

    redirect_config = link.redirect_config
    project = redirect_config.project

    image = Grovs::Links::LOGO
    name = ""

    instance = project.instance
    if instance
      name = instance.production.name
    end

    default_fallback = redirect_config.default_fallback
    deeplink = "#{instance.uri_scheme}://#{link.path}"

    # Build redirect data for each platform
    phone_config = map_redirect_to_configuration(name, image, nil, deeplink, phone_redirect, default_fallback, nil, nil, nil, redirect_config, link)
    tablet_config = map_redirect_to_configuration(name, image, nil, deeplink, tablet_redirect, default_fallback, nil, nil, nil, redirect_config, link)

    if phone_config.nil? || tablet_config.nil?
      return nil
    end

    if phone_redirect && tablet_redirect.nil?
      tablet_config = phone_config
    end

    {"phone": phone_config, "tablet": tablet_config}
  end

  def store_links_for_project(project)
    android_application = project.instance.android_application
    ios_application = project.instance.ios_application

    google_link = nil
    if android_application
      android_config = android_application.configuration
      if android_config
        google_link = google_play_link(android_config.identifier)
      end
    end

    apple_link = nil
    if ios_application
      ios_config = ios_application.configuration
      if ios_config
        appstore_result = AppstoreService.fetch_image_and_title_for_identifier(ios_config.bundle_id)

        appstore_id = appstore_result[:appstore_id]
        apple_link = appstore_link_for(appstore_id)
      end
    end

    {apple: apple_link, google: google_link}
  end

  def map_redirect_to_configuration(title, image, appstore_link, deeplink, redirect, default_fallback, device, project, show_preview, redirect_config, link)
    appstore = nil
    fallback = default_fallback

    if !redirect || !redirect.enabled
      appstore = nil
      deeplink = nil
    end

    if redirect && redirect.fallback_url
      fallback = redirect.fallback_url
    end

    if redirect && redirect.appstore == true
      appstore = appstore_link

      if appstore_link.blank?
        fallback = default_fallback
      end
    end

    show_preview = false if show_preview.nil?

    has_app_installed = false
    if device && project
      has_app_installed = InstalledApp.fetch_for_device_and_project(device.id, project.id) != nil
    end

    fallback = add_query_params_to_link(fallback, link)

    build_configuration(title, image, appstore, deeplink, fallback, has_app_installed, nil, show_preview)
  end

  def build_configuration(title, image, appstore, deeplink, fallback, has_app_installed, open_app_if_installed, show_preview)
    config = {}
    config["title"] = title
    config["image"] = image
    config["deeplink"] = deeplink
    config["appstore"] = appstore
    config["fallback"] = fallback
    config["has_app_installed"] = has_app_installed
    config["show_preview"] = show_preview
    config["open_app_if_installed"] = open_app_if_installed

    config
  end

  def config_for_custom_redirect(config, show_preview, redirect, link, project)
    unless config
      return nil
    end

    show_preview = false if show_preview.nil?

    fallback = add_query_params_to_link(config.url, link)

    name_and_image = name_and_image_for_project(project)
    name = name_and_image[:name]
    image = name_and_image[:image]

    open_app_if_installed = config.open_app_if_installed
    generic_conf = build_configuration(name, image, nil, nil, fallback, false, open_app_if_installed, show_preview)

    phone_config = generic_conf
    tablet_config = generic_conf

    {"phone": phone_config, "tablet": tablet_config}
  end

  def config_for_custom_redirect_desktop(link, redirect, project)
    redirect_url = link.desktop_custom_redirect
    unless redirect_url
      return nil
    end

    # Output the new URL
    redirect_url = add_query_params_to_link(redirect_url.url, link)
    show_preview = false

    name_and_image = name_and_image_for_project(project)
    name = name_and_image[:name]
    image = name_and_image[:image]

    generic_conf = build_configuration(name, image, nil, nil, redirect_url, false, nil, show_preview)

    {"linksquared": generic_conf, "mac": generic_conf, "windows": generic_conf, fallback: generic_conf}
  end

  def add_query_params_to_link(url, link)
    # Check if the URL is nil, empty, or cannot be parsed
    return url if url.nil? || url.strip.empty? || !uri_valid?(url)

    # Parse the URL
    uri = URI.parse(url)

    # Parse the existing query parameters
    query_params = URI.decode_www_form(uri.query || '')

    # Add the query parameters
    query_params << ['utm_campaign', link.tracking_campaign] if link.tracking_campaign
    query_params << ['utm_source', link.tracking_source] if link.tracking_source
    query_params << ['utm_medium', link.tracking_medium] if link.tracking_medium

    unless query_params.empty?
      # Rebuild the query string with the new parameters
      uri.query = URI.encode_www_form(query_params)
    end


    # Output the new URL
    uri.to_s
  end

  def build_generated_page_config(title, image, qr_link, android_link, ios_link)
    qr = RQRCode::QRCode.new(qr_link)

    qr = qr.as_png(size: 500)
    logo = ChunkyPNG::Image.from_file('app/assets/images/logo-for-qr.png')
    qr.compose!(logo, 200, 200)

    config = {}

    config["title"] = title
    config["image"] = image
    qr_png_data = Base64.strict_encode64(qr.to_blob)
    config["qr"] = qr_png_data

    config["android"] = android_link
    config["ios"] = ios_link

    config
  end

  def validate_link(link)
    redirect_config = link.redirect_config
    unless redirect_config
      return nil
    end

    project = redirect_config.project
    unless project
      return nil
    end

    true
  end

  def appstore_link_for(app_id)
    if !app_id || app_id == ""
      return nil
    end

    "https://apps.apple.com/us/app/id#{app_id}"
  end

  def google_play_link(identifier)
    unless identifier
      return nil
    end

    "https://play.google.com/store/apps/details?id=#{identifier}"
  end

  def uri_valid?(url)
    URI.parse(url)
    true
  rescue URI::InvalidURIError
    false
  end
end
