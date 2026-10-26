# The messages inbox is gone; apps already released still ask for it, and these answers are what they can parse.
class Api::V1::Sdk::NotificationsController < Api::V1::Sdk::BaseController
  wrap_parameters false

  # Always 200 with a JSON object and its key: old Android retries for ever on anything else, old iOS alerts.
  def notifications_for_device = render(json: { notifications: [] }, status: :ok)

  def notifications_to_display_automatically = render(json: { notifications: [] }, status: :ok)

  def number_of_unread_notifications = render(json: { number_of_unread_notifications: 0 }, status: :ok)

  # Whatever id is sent: an app may still hold a message it loaded before the inbox was removed.
  def mark_notification_as_read = render(json: { message: "Marked as read" }, status: :ok)
end
