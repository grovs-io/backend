class NotificationMessageService

  def self.add_messages_for_new_visitor(visitor)
    project = visitor.project
    notifications = project.notifications.joins(:notification_target).where(notification_target: {new_users: true}, archived: false)

    # Add messages for all notifications
    notifications.each do |notification|
      message = NotificationMessage.new
      message.visitor = visitor
      message.notification = notification

      message.save!
    end
  end

  def self.create_notification_messages_for_existing_users(notification)
    target = notification.notification_target
    if !target || !target.existing_users
      Rails.logger.warn("Could not find target")
      return
    end

    if notification.notification_messages.count > 0
      Rails.logger.warn("No messages")
      return
    end

    platforms = target.platforms
    if platforms.nil? || platforms.empty?
      # No platform restriction - create for all platforms
      self.create_messages_for_platform(notification, Grovs::Platforms::IOS)
      self.create_messages_for_platform(notification, Grovs::Platforms::ANDROID)
      self.create_messages_for_platform(notification, Grovs::Platforms::WEB)
    else
      if platforms.include?(Grovs::Platforms::IOS)
        # Create notifications for iOS
        self.create_messages_for_platform(notification, Grovs::Platforms::IOS)
      end

      if platforms.include?(Grovs::Platforms::ANDROID)
        # Create notifications for ANDROID
        self.create_messages_for_platform(notification, Grovs::Platforms::ANDROID)
      end

      if platforms.include?(Grovs::Platforms::DESKTOP) || platforms.include?(Grovs::Platforms::WEB)
        # Create notifications for WEB
        self.create_messages_for_platform(notification, Grovs::Platforms::WEB)
      end
    end
  end

  private
  
  def self.create_messages_for_platform(notification, platform)
    visitors = Visitor.joins(:device).includes(:device).where(devices: { platform: platform }, visitors: {project_id: notification.project_id})
    self.create_messages_for_visitors(notification, visitors)
  end
  
  def self.create_messages_for_visitors(notification, visitors)
    messages = []
    visitors.each do |visitor|
      message = NotificationMessage.new
      message.visitor = visitor
      message.notification = notification

      messages << message
    end

    # without validations
    NotificationMessage.import messages, validate: false, batch_size: 10000

    self.send_push_notifications_for_visitors(notification, visitors)
  end

  def self.send_push_notifications_for_visitors(notification, visitors)
    unless notification.send_push
      return
    end

    visitors.each do |visitor|
      self.send_push_to_visitor(visitor, notification)
    end

    Rails.logger.debug("do rpush push")
    Rpush.push
    Rails.logger.debug("done rpush push")
  end

  def self.send_push_to_visitor(visitor, notification)
    device = visitor.device

    Rails.logger.debug("Send push #{visitor.inspect}")

    push = device&.push_token
    unless push
      return
    end

    RpushService.send_push_for_notification_and_visitor(notification, visitor)
  end

end