module CustomRedirectsHandler

  def update_custom_redirects_for_link(link)
    ActiveRecord::Base.transaction do
      # IOS
      ios_data = ios_custom_redirect_param
      if ios_data && ios_data["url"]
        link.ios_custom_redirect&.destroy
        link.custom_redirects.create!(
          platform: Grovs::Platforms::IOS,
          url: ios_data["url"],
          open_app_if_installed: ios_data["open_app_if_installed"]
        )
      else
        link.ios_custom_redirect&.destroy
      end

      # ANDROID
      android_data = android_custom_redirect_param
      if android_data && android_data["url"]
        link.android_custom_redirect&.destroy
        link.custom_redirects.create!(
          platform: Grovs::Platforms::ANDROID,
          url: android_data["url"],
          open_app_if_installed: android_data["open_app_if_installed"]
        )
      else
        link.android_custom_redirect&.destroy
      end

      # DESKTOP
      desktop_data = desktop_custom_redirect_param
      if desktop_data
        link.desktop_custom_redirect&.destroy
        link.custom_redirects.create!(
          platform: Grovs::Platforms::DESKTOP,
          url: desktop_data["url"],
          open_app_if_installed: false # or nil, since desktop doesn't use this
        )
      else
        link.desktop_custom_redirect&.destroy
      end
    end
  end

  # Param helpers
  def ios_custom_redirect_param
    parse_custom_redirect_param(:ios_custom_redirect, require_open_app_if_installed: true)
  end

  def android_custom_redirect_param
    parse_custom_redirect_param(:android_custom_redirect, require_open_app_if_installed: true)
  end

  def desktop_custom_redirect_param
    parse_custom_redirect_param(:desktop_custom_redirect, require_open_app_if_installed: false)
  end

  private

  def parse_custom_redirect_param(param_key, require_open_app_if_installed:)
    value = params[param_key]
  
    # If value is a stringified JSON, parse it
    if value.is_a?(String)
      begin
        value = JSON.parse(value)
      rescue JSON::ParserError
        return nil
      end
    end
  
    # If it's ActionController::Parameters, permit expected keys
    if value.is_a?(ActionController::Parameters)
      value = value.permit(:url, :open_app_if_installed).to_h
    end
  
    # Ensure it's a plain hash and has expected structure
    unless value.is_a?(Hash)
      return nil
    end
  
    value = value.symbolize_keys
  
    if require_open_app_if_installed && !value.key?(:open_app_if_installed)
      return nil
    end
   
    value.transform_keys(&:to_s)
    
  end
end