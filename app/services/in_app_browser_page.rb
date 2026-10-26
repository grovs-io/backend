class InAppBrowserPage
  PLATFORMS = [Grovs::Platforms::IOS, Grovs::Platforms::ANDROID].freeze
  HINTS = {
    Grovs::Platforms::IOS => "Not opening? Tap ⋯ and choose Open in browser.",
    Grovs::Platforms::ANDROID => "Not opening? Tap ⋮ and choose Open in browser."
  }.freeze

  class << self
    def eligible?(link:, platform:, user_agent:)
      return false unless PLATFORMS.include?(platform)

      config = link.redirect_config
      return false unless config&.public_send("in_app_browser_page_#{platform}")

      opens_app?(link, config, platform, user_agent)
    end

    def button_url(redirect_url:, link:, platform:, in_app_browser:)
      return redirect_url unless in_app_browser && platform == Grovs::Platforms::ANDROID

      package = android_package(link)
      return redirect_url if package.blank?

      uri = URI.parse(redirect_url)
      return redirect_url unless uri.host == URI.parse(link.access_path).host
      return redirect_url unless URI.decode_www_form(uri.query.to_s).include?(%w[go_to_fallback true])

      "intent://#{uri.host}#{uri.path}?#{uri.query}#Intent;scheme=https;package=#{package};" \
        "S.browser_fallback_url=#{CGI.escape(redirect_url)};end"
    rescue URI::InvalidURIError
      redirect_url
    end

    def hint_text(platform)
      HINTS[platform]
    end

    def android_package(link)
      link.redirect_config&.project&.instance&.android_application&.configuration&.identifier
    end

    private

    # Mirrors WebConfigurationService.configure_for_platform; tablets with their own redirect are skipped.
    def opens_app?(link, config, platform, user_agent)
      custom = link.custom_redirect_for(platform)
      return custom.open_app_if_installed if custom

      ios = platform == Grovs::Platforms::IOS
      if Browser.new(user_agent.to_s).device.tablet?
        tablet = ios ? config.ios_tablet_redirect : config.android_tablet_redirect
        return false if tablet
      end

      phone = ios ? config.ios_phone_redirect : config.android_phone_redirect
      phone&.enabled || false
    end
  end
end
