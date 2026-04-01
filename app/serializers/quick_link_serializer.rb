class QuickLinkSerializer < BaseSerializer
  attributes :path, :title, :subtitle,
             :ios_phone, :ios_tablet,
             :android_phone, :android_tablet,
             :desktop, :desktop_mac, :desktop_windows, :desktop_linux


  def build(**)
    h = super()
    h["image"] = record.image_resource
    h["access_path"] = record.access_path
    h
  end
end
