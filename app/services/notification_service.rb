class NotificationService
  def initialize(project:)
    @project = project
  end

  # Transactional: creates Notification + Target, enqueues SendMessagesJob. Returns Notification.
  def create(notification_attrs:, target_attrs:)
    notification = nil

    ActiveRecord::Base.transaction do
      notification = Notification.new(notification_attrs)
      notification.project = @project

      target = NotificationTarget.new(target_attrs)
      notification.notification_target = target

      notification.save!
      target.save!

      notification.reload
    end

    SendMessagesJob.perform_async(notification.id)
    notification
  end

  # Returns paginated notifications with read_count.
  def list(archived:, page:, for_new_users: nil, search_term: nil, per_page: nil)
    notifications = @project.notifications
      .where(archived: archived)
      .joins(:notification_target)
      .includes(:notification_target, project: :domain)

    unless for_new_users.nil?
      notifications = notifications.where(notification_targets: { new_users: for_new_users })
    end

    if search_term.present?
      term = search_term.strip.downcase
      notifications = notifications.where(
        "LOWER(title) LIKE ? OR LOWER(subtitle) LIKE ?",
        "%#{term}%", "%#{term}%"
      )
    end

    notifications = notifications.select(
      "notifications.*, (SELECT COUNT(*) FROM notification_messages " \
      "WHERE notification_messages.notification_id = notifications.id " \
      "AND notification_messages.read = TRUE) AS read_count"
    )

    notifications = notifications.order(updated_at: :desc).page(page)
    notifications = notifications.per(per_page) if per_page

    notifications
  end

  # Archives notification. Raises if targeting existing_users. Returns Notification.
  def archive(notification:)
    if notification.notification_target.existing_users
      raise ArgumentError, "You can't archive a notification for existing users!"
    end

    notification.archived = true
    notification.save!
    notification
  end
end
