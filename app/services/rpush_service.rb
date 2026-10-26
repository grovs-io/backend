class RpushService

  def self.update_android_rpush_app(push_config_id)
    push_config = AndroidPushConfiguration.find_by(id: push_config_id)
    if !push_config || !push_config.certificate.attached?
      return
    end

    remove_app(Rpush::Fcm::App.find_by(name: push_config.name))


    fcm_app = self.create_android_app(push_config, push_config.name)
    fcm_app.save!
  end

  def self.update_ios_rpush_app(push_config_id)
    push_config = IosPushConfiguration.find_by(id: push_config_id)
    if !push_config || !push_config.certificate.attached?
      return
    end

    remove_app(Rpush::Apnsp8::App.find_by(name: "#{push_config.name}-development"))
    remove_app(Rpush::Apnsp8::App.find_by(name: "#{push_config.name}-production"))

    development = self.create_apple_apns2_app(push_config, "#{push_config.name}-development", "development")
    production = self.create_apple_apns2_app(push_config, "#{push_config.name}-production", "production")

    development.save!
    production.save!
  end

  PURGE_BATCH = 10_000

  # Sent history is left to RpushAppHistoryPurgeJob; rows mid-send finish; racing inserts are orphans.
  def self.remove_app(app)
    return if app.nil?

    app.delete
    purge_unsent(unsent_rows.where(app_id: app.id, processing: false))
    ActiveRecord.after_all_transactions_commit { RpushAppHistoryPurgeJob.perform_async(app.id) }
  end

  # rpush raises on a row whose app is gone, stranding its fetch; a live batch settles within 60s.
  def self.purge_orphans
    orphans = unsent_rows.where.not(app_id: Rpush::Client::ActiveRecord::App.select(:id))
    purge_unsent(orphans.where("NOT processing OR updated_at < ?", 2.minutes.ago))
  end

  def self.unsent_rows = Rpush::Client::ActiveRecord::Notification.where(delivered: false, failed: false)

  def self.purge_unsent(scope)
    purged = 0
    loop do
      sql = "DELETE FROM rpush_notifications WHERE id IN (#{scope.limit(PURGE_BATCH).select(:id).to_sql}) RETURNING id"
      ids = Rpush::Client::ActiveRecord::Notification.transaction do
        Rpush::Client::ActiveRecord::Notification.connection.exec_query(sql).rows.flatten.tap { |deleted| PushOutcomes.abandoned(deleted) }
      end
      return purged if ids.empty?

      purged += ids.size
    end
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

  def self.create_android_app(push_config, name)
    fcm_app = Rpush::Fcm::App.new
    fcm_app.name = name
    fcm_app.firebase_project_id = push_config.firebase_project_id
    fcm_app.json_key = push_config.certificate.download
    fcm_app.connections = Integer(ENV.fetch("RPUSH_FCM_CONNECTIONS", 30))
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
    app.connections = Integer(ENV.fetch("RPUSH_APNS_CONNECTIONS", 2))
    app.save!

    app
  end

end