class RedirectConfigSerializer < BaseSerializer
  attributes :default_fallback, :show_preview_ios, :show_preview_android


  def build(**)
    h = super()
    h["ios"] = { "phone" => record.ios_phone_redirect, "tablet" => record.ios_tablet_redirect }
    h["android"] = { "phone" => record.android_phone_redirect, "tablet" => record.android_tablet_redirect }
    h["desktop"] = { "all" => record.desktop_all_redirect }
    h
  end
end
