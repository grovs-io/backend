# No auth, no project or device data: a static page that relays postMessages for the dashboard's HTML preview.
class Public::InAppPreviewController < Public::BaseController
  ORIGINS = Grovs.in_app_preview_origins.freeze

  # The hosts InAppDefinition::LOCAL_HTTP accepts outside production, so the preview shows what validation allows.
  LOCAL_MEDIA = Rails.env.local? ? " http://localhost:* http://127.0.0.1:* http://*.lvh.me:* http://*.localhost:*" : ""
  CSP = "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:#{LOCAL_MEDIA}; " \
        "img-src https: data:#{LOCAL_MEDIA}; media-src https:#{LOCAL_MEDIA}; font-src https: data:; " \
        "connect-src https:; frame-src https:; " \
        "frame-ancestors #{ORIGINS.empty? ? "'none'" : ORIGINS.join(' ')}".freeze

  # Built once at boot; to_json already escapes "<" so neither value can end the script tag early.
  PAGE = begin
    template = File.read(Rails.root.join("ee/config/in_app/preview.html"))
    bridge_js = File.read(Rails.root.join("ee/config/in_app/bridge.js"))
    template.sub("__ALLOWED_ORIGINS__") { ORIGINS.to_json }
            .sub("__BRIDGE_JS__") { bridge_js.to_json }
  end.freeze

  def show
    response.headers.delete("X-Frame-Options")
    response.headers["Content-Security-Policy"] = CSP
    render html: PAGE.html_safe, layout: false # rubocop:disable Rails/OutputSafety
  end
end
