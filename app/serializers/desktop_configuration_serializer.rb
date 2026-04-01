class DesktopConfigurationSerializer < BaseSerializer
  attributes :fallback_url, :generated_page,
             :mac_enabled, :mac_uri,
             :windows_enabled, :windows_uri
end
