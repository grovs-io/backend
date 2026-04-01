class Api::V1::Sdk::NotificationsController < Api::V1::Sdk::BaseController
  def notifications_for_device
    notifications = @visitor.notification_messages
                            .joins(notification: :notification_target)
                            .includes(notification: [:notification_target, { project: :domain }])
                            .where(
                              "notification_targets.platforms IS NULL OR " \
                              "notification_targets.platforms = '{}' OR " \
                              "? = ANY(notification_targets.platforms)", @platform
                            )
    notifications = notifications.order(updated_at: :desc)
    notifications = notifications.page(page_param)

    render json: {notifications: NotificationMessageSerializer.serialize(notifications)}, status: :ok
  end

  def number_of_unread_notifications
    messages = @visitor.notification_messages.where(read: false)

    render json: {number_of_unread_notifications: messages.count}, status: :ok
  end

  def mark_notification_as_read
    notification = @visitor.notification_messages.find_by(id: id_param)
    unless notification
      render json: {error: "Notification not found"}, status: :not_found
      return
    end

    notification.read = true
    notification.save!

    render json: {message: "Marked as read"}, status: :ok
  end

  def notifications_to_display_automatically
    notifications = @visitor
                    .notification_messages
                    .includes(notification: [:notification_target, { project: :domain }])
                    .joins(:notification)
                    .where(
                        notification_messages: { read: false },
                        notifications: { auto_display: true }
                    )
                    .order(created_at: :desc)

    render json: {notifications: NotificationMessageSerializer.serialize(notifications)}, status: :ok
  end

  private

  def page_param
    params.require(:page)
  end

  def id_param
    params.require(:id)
  end
end
