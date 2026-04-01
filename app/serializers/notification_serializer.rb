class NotificationSerializer < BaseSerializer
  attributes :id, :title, :subtitle, :html, :archived,
             :auto_display, :send_push, :updated_at


  def build(**)
    h = super()
    h["target"] = NotificationTargetSerializer.serialize(record.notification_target)
    h["access_url"] = record.access_url
    h
  end
end
