require 'rqrcode'

class WebConfigurationService
  PLATFORM_CONFIG = {
    ios: {
      show_preview: lambda { |link, rc| 
        v = link.show_preview_ios
        v.nil? ? rc.show_preview_ios : v
      },
      custom_redirect: ->(link) { link.ios_custom_redirect },
      phone_redirect: ->(rc) { rc.ios_phone_redirect },
      tablet_redirect: ->(rc) { rc.ios_tablet_redirect },
      application: ->(instance) { instance.ios_application },
      fetch_store_metadata: ->(config) { AppstoreService.fetch_image_and_title_for_identifier(config.bundle_id) },
      store_link: lambda { |result, _config|
        appstore_id = result[:appstore_id]
        appstore_id.present? ? "https://apps.apple.com/us/app/id#{appstore_id}" : nil
      },
      tracking_params: lambda { |link|
        [
          link.tracking_campaign ? ['ct', link.tracking_campaign] : nil,
          link.tracking_source ? ['at', link.tracking_source] : nil,
          link.tracking_medium ? ['pt', link.tracking_medium] : nil
        ].compact
      }
    },
    android: {
      show_preview: lambda { |link, rc| 
        v = link.show_preview_android
        v.nil? ? rc.show_preview_android : v
      },
      custom_redirect: ->(link) { link.android_custom_redirect },
      phone_redirect: ->(rc) { rc.android_phone_redirect },
      tablet_redirect: ->(rc) { rc.android_tablet_redirect },
      application: ->(instance) { instance.android_application },
      fetch_store_metadata: ->(config) { GooglePlayService.fetch_image_and_title_for_identifier(config.identifier) },
      store_link: ->(_result, config) { "https://play.google.com/store/apps/details?id=#{config.identifier}" },
      tracking_params: lambda { |link|
        [
          ['referrer', link.access_path],
          link.tracking_campaign ? ['utm_campaign', link.tracking_campaign] : nil,
          link.tracking_source ? ['utm_source', link.tracking_source] : nil,
          link.tracking_medium ? ['utm_medium', link.tracking_medium] : nil
        ].compact
      }
    }
  }.freeze

  class << self
    include WebConfigurationService::ConfigHelpers

    def configuration_for_ios(link, device, _project)
      configure_for_platform(link, device, :ios)
    end

    def configure_for_android(link, device, _project)
      configure_for_platform(link, device, :android)
    end

    def configure_for_platform(link, device, platform_key)
      return nil unless validate_link(link)

      pc = PLATFORM_CONFIG[platform_key]
      redirect_config = link.redirect_config
      project = redirect_config.project

      show_preview = pc[:show_preview].call(link, redirect_config)

      custom_redirect = config_for_custom_redirect(pc[:custom_redirect].call(link), show_preview, redirect_config, link, project)
      return custom_redirect if custom_redirect

      phone_redirect = pc[:phone_redirect].call(redirect_config)
      tablet_redirect = pc[:tablet_redirect].call(redirect_config)

      instance = project.instance
      return generic_config(link, phone_redirect, tablet_redirect) unless instance

      application = pc[:application].call(instance)
      return generic_config(link, phone_redirect, tablet_redirect) unless application

      configuration = application.configuration
      return generic_config(link, phone_redirect, tablet_redirect) unless configuration

      store_result = pc[:fetch_store_metadata].call(configuration)
      name = store_result[:title]
      image = store_result[:image]
      image = Grovs::Links::LOGO if image.blank?
      name = instance.production.name if name.blank?

      default_fallback = redirect_config.default_fallback
      deeplink = "#{instance.uri_scheme}://#{link.path}"
      appstore_link = pc[:store_link].call(store_result, configuration)

      if appstore_link
        uri = URI.parse(appstore_link)
        query_params = URI.decode_www_form(uri.query || '')
        query_params.concat(pc[:tracking_params].call(link))
        uri.query = URI.encode_www_form(query_params) unless query_params.empty?
        appstore_link = uri.to_s
      end

      phone_config = map_redirect_to_configuration(name, image, appstore_link, deeplink, phone_redirect, default_fallback, device, project, show_preview, 
redirect_config, link)
      tablet_config = map_redirect_to_configuration(name, image, appstore_link, deeplink, tablet_redirect, default_fallback, device, project, show_preview, 
redirect_config, link)

      return nil if phone_config.nil? || tablet_config.nil?
      tablet_config = phone_config if phone_redirect && tablet_redirect.nil?

      { "phone": phone_config, "tablet": tablet_config }
    end

    def configure_for_desktop(link)
      unless validate_link(link)
        return nil
      end

      redirect_config = link.redirect_config
      project = redirect_config.project
      desktop_application = project.instance.desktop_application

      custom_redirect = config_for_custom_redirect_desktop(link, redirect_config, project)
      if custom_redirect
        # The link has a custom redirect set
        return custom_redirect
      end

      default_fallback  = redirect_config.default_fallback
      has_fallback_explicitly_set = false
      if desktop_application
        configuration = desktop_application.configuration

        if configuration.fallback_url
          has_fallback_explicitly_set = true
          default_fallback = configuration.fallback_url
        end
      end

      # Reguired data from configs
      name_and_image = name_and_image_for_project(project)
      name = name_and_image[:name]
      image = name_and_image[:image]

      links = store_links_for_project(project)
      apple_link = links[:apple]
      google_link = links[:google]

      domain = link.domain
      full_link = link.full_path(domain)

      all_config = redirect_config.desktop_all_redirect
      show_preview = false

      all_config_map = nil
      if all_config
        # build_configuration(title, image, appstore, deeplink, fallback)
        all_config_map = build_configuration(name, image, nil, nil, all_config.fallback_url, false, nil, show_preview)
      end

      generic_config_map = build_generated_page_config(name, image, full_link, google_link, apple_link)
      if has_fallback_explicitly_set
        generic_config_map = nil
      end

      {"linksquared": generic_config_map, "mac": all_config_map, "windows": all_config_map, fallback: default_fallback}
    end

    def configuration_has_redirect?(config)
      if !config || (config["deeplink"].blank? && config["appstore"].blank? && config["fallback"].blank?)
        return false
      end

      true
    end

    def name_and_image_for_project(project)
      name = project.name
      image = nil

      android_application = project.instance.android_application
      ios_application = project.instance.ios_application

      if ios_application
        ios_config = ios_application.configuration
        if ios_config
          appstore_result = AppstoreService.fetch_image_and_title_for_identifier(ios_config.bundle_id)
          name = appstore_result[:title]
          image = appstore_result[:image]
        end
      end

      if !image && android_application
        android_config = android_application.configuration

        if android_config
          appstore_result = GooglePlayService.fetch_image_and_title_for_identifier(android_config.identifier)
          name = appstore_result[:title]
          image = appstore_result[:image]
        end
      end

      if !name || name == ""
        name = project.name
      end

      if !image || image == ""
        image = Grovs::Links::LOGO
      end

      {name: name, image: image}
    end


    def name_and_image_for_project_and_platform(project, platform)
      name = project.name
      image = nil

      android_application = project.instance.android_application
      ios_application = project.instance.ios_application

      if platform == Grovs::Platforms::IOS && ios_application
        ios_config = ios_application.configuration
        if ios_config
          appstore_result = AppstoreService.fetch_image_and_title_for_identifier(ios_config.bundle_id)
          name = appstore_result[:title]
          image = appstore_result[:image]
        end
      end

      if platform == Grovs::Platforms::ANDROID && android_application
        android_config = android_application.configuration

        if android_config
          appstore_result = GooglePlayService.fetch_image_and_title_for_identifier(android_config.identifier)
          name = appstore_result[:title]
          image = appstore_result[:image]
        end
      end

      if !name || name == ""
        name = project.name
      end

      if !image || image == ""
        image = Grovs::Links::LOGO
      end

      {name: name, image: image}
    end
  end
end
