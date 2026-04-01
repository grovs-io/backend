class NotificationMessageSerializer < BaseSerializer
  attributes :id, :read


  def build(**)
    h = super()
    h["access_url"] = record.notification.access_url
    h["updated_at"] = record.notification.updated_at.as_json
    h["title"] = record.notification.title
    h["subtitle"] = record.notification.subtitle
    h["auto_display"] = record.notification.auto_display
    h
  end
end
