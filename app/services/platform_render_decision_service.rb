class PlatformRenderDecisionService
  class << self
    # Returns a decision hash: {action:, template:, url:, locals:, name:}
    def call(device:, link:, project:, go_to_fallback:)
      # Try preview first
      preview_decision = check_preview(device, link, project, go_to_fallback)
      return preview_decision if preview_decision

      # Then platform-specific template
      platform_decision = platform_template(device, link, project, go_to_fallback)
      return platform_decision if platform_decision

      # Fallback
      { action: :default_redirect, name: link.redirect_config.project.name || "" }
    end

    private

    def check_preview(device, link, project, go_to_fallback)
      case device.platform
      when Grovs::Platforms::IOS
        check_preview_for_platform(
          device: device, link: link, project: project,
          show_preview_field: :show_preview_ios,
          config_show_preview_field: :show_preview_ios,
          go_to_fallback: go_to_fallback,
          platform_template_method: :ios_template
        )
      when Grovs::Platforms::ANDROID
        check_preview_for_platform(
          device: device, link: link, project: project,
          show_preview_field: :show_preview_android,
          config_show_preview_field: :show_preview_android,
          go_to_fallback: go_to_fallback,
          platform_template_method: :android_template
        )
      end
    end

    def check_preview_for_platform(device:, link:, project:, show_preview_field:, config_show_preview_field:, go_to_fallback:, platform_template_method:)
      show_preview = link.send(show_preview_field)
      show_preview = project.redirect_config.send(config_show_preview_field) if show_preview.nil?
      return nil unless show_preview

      if [nil, false].include?(go_to_fallback)
        preview_url = LinksService.build_preview_url(link)
        return { action: :redirect, url: preview_url }
      end

      if go_to_fallback == true
        decision = send(platform_template_method, link, device, project, go_to_fallback)
        return decision if decision
      end

      nil
    end

    def platform_template(device, link, project, go_to_fallback)
      case device.platform
      when Grovs::Platforms::IOS
        ios_template(link, device, project, go_to_fallback)
      when Grovs::Platforms::ANDROID
        android_template(link, device, project, go_to_fallback)
      when Grovs::Platforms::MAC, Grovs::Platforms::WINDOWS, Grovs::Platforms::DESKTOP, Grovs::Platforms::WEB
        desktop_template(link)
      end
    end

    def ios_template(link, device, project, go_to_fallback)
      config = WebConfigurationService.configuration_for_ios(link, device, project)
      return nil unless config

      unless WebConfigurationService.configuration_has_redirect?(config[:phone]) ||
             WebConfigurationService.configuration_has_redirect?(config[:tablet])
        return { action: :default_redirect, name: link.redirect_config.project.name || "" }
      end

      if go_to_fallback
        url = LinkDisplayService.fallback_url(config)
        return { action: :redirect, url: url } if url
      end

      { action: :render, template: "public/display/ios_link_handling", locals: { ios_config: config.to_json } }
    end

    def android_template(link, device, project, go_to_fallback)
      config = WebConfigurationService.configure_for_android(link, device, project)
      return nil unless config

      unless WebConfigurationService.configuration_has_redirect?(config[:phone]) ||
             WebConfigurationService.configuration_has_redirect?(config[:tablet])
        return { action: :default_redirect, name: link.redirect_config.project.name || "" }
      end

      if go_to_fallback
        url = LinkDisplayService.fallback_url(config)
        return { action: :redirect, url: url } if url
      end

      { action: :render, template: "public/display/android_link_handling", locals: { android_config: config.to_json } }
    end

    def desktop_template(link)
      config = WebConfigurationService.configure_for_desktop(link)
      return nil unless config

      { action: :render, template: "public/display/desktop_link_handling", locals: { desktop_config: config.to_json } }
    end
  end
end
