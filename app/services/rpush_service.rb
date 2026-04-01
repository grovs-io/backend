class RpushService

  def self.update_android_rpush_app(push_config_id)
    push_config = AndroidPushConfiguration.find_by(id: push_config_id)
    if !push_config || !push_config.certificate.attached?
      return
    end

    app = Rpush::Fcm::App.find_by(name:push_config.name)
    if app
      app.destroy!
    end


    fcm_app = self.create_android_app(push_config, push_config.name)
    fcm_app.save!
  end

  def self.update_ios_rpush_app(push_config_id)
    push_config = IosPushConfiguration.find_by(id: push_config_id)
    if !push_config || !push_config.certificate.attached?
      return
    end

    app = Rpush::Apnsp8::App.find_by(name:"#{push_config.name}-development")
    if app
      app.destroy!
    end

    app = Rpush::Apnsp8::App.find_by(name:"#{push_config.name}-production")
    if app
      app.destroy!
    end

    development = self.create_apple_apns2_app(push_config, "#{push_config.name}-development", "development")
    production = self.create_apple_apns2_app(push_config, "#{push_config.name}-production", "production")

    development.save!
    production.save!
  end

  def self.app_for_platform(platform, project)
    unless project
      return
    end

    if platform == Grovs::Platforms::IOS
      app = project.instance.ios_application
      return nil unless app

      config = app.ios_configuration
      return nil unless config

      push_config = config.ios_push_configuration
      return nil unless push_config

      app_name = push_config.name + (project.test ? "-development" : "-production")
      return Rpush::Apnsp8::App.find_by(name:app_name)
    end

    if platform == Grovs::Platforms::ANDROID
      app = project.instance.android_application
      return nil unless app

      config = app.android_configuration
      return nil unless config

      push_config = config.android_push_configuration
      return nil unless push_config

      Rpush::Fcm::App.find_by(name: push_config.name)
    end
  end

  def self.send_push_for_notification_and_visitor(notification, visitor)
    platform = visitor.device&.platform
    push_token = visitor.device&.push_token
    if !platform || !push_token
      Rails.logger.warn("Doesn't have platform or token")
      return
    end

    if platform == Grovs::Platforms::IOS
      self.send_ios_push(notification, push_token)
    end

    if platform == Grovs::Platforms::ANDROID
      self.send_android_push(notification, push_token)
    end

  end

  private

  def self.send_ios_push(notification, push_token)
    app = self.app_for_platform(Grovs::Platforms::IOS, notification.project)
    unless app
      Rails.logger.error("can not find app for project #{notification.project.inspect}")
      return
    end

    n = Rpush::Apnsp8::Notification.new
    n.app = app
    n.device_token = push_token
    n.alert = { title: notification.title, subtitle: notification.subtitle }
    n.save!

    Rails.logger.debug("Notification created")
  end

  def self.send_android_push(notification, push_token)
    app = self.app_for_platform(Grovs::Platforms::ANDROID, notification.project)
    unless app
      return
    end

    n = Rpush::Fcm::Notification.new
    n.app = app
    n.device_token = push_token
    n.notification = {
          body: notification.subtitle,
          title: notification.title
        }
    n.data = {linksquared: "true"}
    n.save!
  end

  def self.create_android_app(push_config, name)
    fcm_app = Rpush::Fcm::App.new
    fcm_app.name = name
    fcm_app.firebase_project_id = push_config.firebase_project_id
    fcm_app.json_key = push_config.certificate.download
    fcm_app.connections = 30
    fcm_app.save!

    fcm_app
  end

  def self.create_apple_apns2_app(push_config, name, environment)
    app = Rpush::Apnsp8::App.new
    app.name = name
    app.apn_key = push_config.certificate.download
    app.environment = environment
    app.apn_key_id = push_config.certificate_password
    app.team_id = push_config.ios_configuration.app_prefix
    app.bundle_id = push_config.ios_configuration.bundle_id
    app.connections = 1
    app.save!

    app
  end

end