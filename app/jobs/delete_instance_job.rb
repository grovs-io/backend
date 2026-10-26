# app/jobs/delete_instance_job.rb
class DeleteInstanceJob
  include Sidekiq::Worker
  # Every step is an idempotent delete, so retries are cheap; a CH outage must not strand a half-deleted tenant.
  sidekiq_options queue: :maintenance, retry: 10

  BATCH_SIZE     = 50_000
  SUB_BATCH_SIZE = 10_000
  # At most this many run at once, so a burst of deletions never holds every maintenance thread from the ticks.
  SLOT_KEY = "delete_instance:running".freeze
  STATEMENT_TIMEOUT = 15.minutes
  # Renewed after the job's SQL statements; longer than one statement may run, so it cannot lapse mid-statement.
  LEASE = (STATEMENT_TIMEOUT * 2).to_i
  RENEW_EVERY = 60
  RETRY_IN = 30
  ACQUIRE_LUA = <<~LUA.freeze
    redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
    if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[2]) then return 0 end
    redis.call('ZADD', KEYS[1], ARGV[3], ARGV[4])
    redis.call('EXPIRE', KEYS[1], ARGV[5])
    return 1
  LUA

  def self.slots(raw = ENV.fetch("DELETE_INSTANCE_CONCURRENCY", "2")) = [Integer(raw), 1].max

  def self.acquire_slot(token)
    now = Time.now.to_f
    argv = [now, slots, now + LEASE, token, LEASE].map(&:to_s)
    REDIS.with { |c| c.eval(ACQUIRE_LUA, keys: [SLOT_KEY], argv: argv) }.to_i == 1
  end

  def perform(instance_id)
    instance = Instance.find_by(id: instance_id)
    unless instance
      log "Instance with ID #{instance_id} not found, skipping deletion.", level: :warn
      return
    end

    @slot = SecureRandom.hex(16)
    return self.class.perform_in(RETRY_IN, instance_id) unless self.class.acquire_slot(@slot)

    owner = Thread.current
    renewer = ActiveSupport::Notifications.subscribe("sql.active_record") { renew_slot if Thread.current == owner }
    begin
      delete_instance(instance)
    ensure
      ActiveSupport::Notifications.unsubscribe(renewer)
      REDIS.with { |c| c.zrem(SLOT_KEY, @slot) }
    end
  end

  private

  def delete_instance(instance)
    # Entitlement is decided now; the row is written only after the teardown succeeds (the Instance row is gone by then).
    audit_entitled = instance.audit_log_enabled?
    audit_target = Audit.target_for(instance)

    project_ids = Project.where(instance_id: instance.id).pluck(:id)

    # Notifications (+ children)
    log "removing notifications for projects"
    remove_notifications_for_projects(project_ids)
    log "notifications removed"

    # IAP webhooks
    log "removing iap webhook messages for projects"
    remove_iap_webhook_messages_for_projects(project_ids)
    log "iap webhook messages removed"

    # Installed apps
    log "removing installed apps for projects"
    remove_installed_apps_for_projects(project_ids)
    log "installed apps removed"

    # Purchase events
    log "remove purchase events for projects"
    remove_purchase_events_for_projects(project_ids)
    log "purchase events removed"

    remove_event_stream_for_projects(project_ids) if defined?(EventDestination)
    remove_segments_for_projects(project_ids) if defined?(Segment)

    # Visitor last visits (FK to links, visitors, projects — must go before all three)
    log "removing visitor last visits for projects"
    remove_visitor_last_visits_for_projects(project_ids)
    log "visitor last visits removed"

    remove_device_last_seens_for_projects(project_ids)

    # Custom hostnames before domains (Cloudflare teardown + FK cleanup)
    log "removing custom hostnames for projects"
    remove_custom_hostnames_for_projects(project_ids)
    log "custom hostnames removed"

    remove_smart_banners_for_projects(project_ids)

    # Links (+ children) and domains
    log "removing links for projects"
    remove_links_for_projects(project_ids)
    log "links removed"

    # Campaigns
    log "removing campaigns for projects"
    remove_campaigns_for_projects(project_ids)
    log "campaigns removed"

    # Redirect configs (+ children)
    log "removing redirect configs for projects"
    remove_redirect_configs_for_projects(project_ids)
    log "redirect configs removed"

    # Applications (per instance) + nested configs
    log "Removing applications for instance: #{instance.id}"
    remove_applications_for_instance(instance.id)
    log "applications removed"

    # Visitors
    log "Remove visitors for projects"
    remove_visitors_for_projects(project_ids)
    log "visitors removed"

    # Project DAU
    log "Remove project daily active users for projects"
    remove_project_daily_active_users_for_projects(project_ids)
    log "project daily active users removed"

    # Visitor daily stats
    log "Remove visitor daily statistics for projects"
    remove_visitor_daily_statistics_for_projects(project_ids)
    log "visitor daily statistics removed"

    # Link daily stats (often PK-less)
    log "remove link daily statistics for projects"
    remove_link_daily_statistics_for_projects(project_ids)
    log "link daily statistics removed"

    # Daily project metrics (may be PK-less in some schemas)
    log "remove daily project metrics for projects"
    remove_daily_project_metrics_for_projects(project_ids)
    log "daily project metrics removed"

    # Screen aliases and dashboards (non-cascading FKs to projects)
    log "remove screen aliases and dashboards for projects"
    remove_screen_aliases_and_dashboards_for_projects(project_ids)
    log "screen aliases and dashboards removed"

    # Before the project rows go: a failed CH sweep must retry while the instance still exists.
    log "removing ClickHouse data for projects"
    raise "ClickHouse delete failed for projects #{project_ids.inspect}" unless ClickhouseDeleteService.delete_projects(project_ids)

    log "ClickHouse deletes queued"

    log "Removing projects"
    Project.unscoped.where(id: project_ids).delete_all
    log "projects removed"

    # Billing rows go with the audit: deleted earlier, a retry would read the instance as unentitled.
    ActiveRecord::Base.transaction do
      EnterpriseSubscription.unscoped.where(instance_id: instance.id).delete_all
      # FK-blocks instance.destroy!; subs before intents (subs reference intents).
      StripeSubscription.unscoped.where(instance_id: instance.id).delete_all
      StripePaymentIntent.unscoped.where(instance_id: instance.id).delete_all
      instance.destroy!
      Audit.record(instance_id: instance.id, action: "instance.deleted", actor: AuditActor.system(self.class.name),
                        target: audit_target, entitled: audit_entitled)
    end
    log "instance #{instance.id} destroyed"
    Rails.logger.warn(message: "audit.instance_deleted", instance_id: instance.id)

  rescue StandardError => e
    log "ERROR: #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}", level: :error
    raise
  end

  def remove_in_app_for_projects(project_ids)
    return unless defined?(InAppSetting) && defined?(SegmentMembership)

    InAppCampaign.where(project_id: project_ids).with_attached_media.find_each do |campaign|
      [campaign.portrait_image, campaign.landscape_image].each { |image| image.purge if image.attached? }
      campaign.media.each(&:purge)
    end
    # In batches first: left to the foreign key, every view would go in the one statement that deletes the campaigns.
    InAppView.where(project_id: project_ids).in_batches(of: 10_000).delete_all if defined?(InAppView)
    if defined?(Journey)
      Journey.where(project_id: project_ids).with_attached_images.find_each { |journey| journey.images.each(&:purge) }
      Journey.where(project_id: project_ids).delete_all
    end
    InAppCampaign.where(project_id: project_ids).delete_all
    InAppSetting.where(project_id: project_ids).delete_all
    InAppMemberships.delete_all_of(SegmentMembership.where(project_id: project_ids))
  end

  # Exports before segments: the export row's foreign key requires it.
  def remove_segments_for_projects(project_ids)
    SegmentExport.where(project_id: project_ids).find_each(&:destroy) if defined?(SegmentExport)
    if defined?(PushCampaign)
      campaigns = PushCampaign.where(project_id: project_ids)
      campaigns.with_attached_image.find_each { |c| c.image.purge if c.image.attached? }
      queued = PushDelivery.where(push_campaign_id: campaigns.select(:id)).where.not(rpush_notification_id: nil).select(:rpush_notification_id)
      Rpush::Notification.where(id: queued, delivered: false, failed: false).delete_all
      campaigns.delete_all
    end
    remove_in_app_for_projects(project_ids) if defined?(InAppCampaign)
    Segment.where(project_id: project_ids).delete_all
  end

  def remove_event_stream_for_projects(project_ids)
    log "removing event destinations and stream tokens"
    EventDestination.where(project_id: project_ids).delete_all
    EventStreamToken.where(project_id: project_ids).delete_all
    project_ids.each do |pid|
      EventStream::Outbox.disable_project!(pid)
      EventStream::Outbox.purge_project!(pid)
    rescue StandardError => e
      log "outbox purge failed for #{pid}: #{e.message}", level: :warn
    end
  end

  def renew_slot
    return if @renewed_at && Time.now - @renewed_at < RENEW_EVERY

    @renewed_at = Time.now

    REDIS.with do |c|
      c.multi do |m|
        m.zadd(SLOT_KEY, Time.now.to_f + LEASE, @slot, xx: true)
        m.expire(SLOT_KEY, LEASE)
      end
    end
  end

  def log(msg, level: :info)
    Sidekiq.logger.public_send(level, "[DeleteInstanceJob] #{msg}")
    Rails.logger.public_send(level,    "[DeleteInstanceJob] #{msg}") if defined?(Rails)
  end

  # -----------------------------
  # Helpers
  # -----------------------------

  # SET LOCAL works only inside a transaction.
  # Allowlist format to prevent SQL injection (SET doesn't support bind params).
  VALID_TIMEOUT = /\A\d+\s?(ms|s|min|h|d)?\z/

  # 2s lock: instance deletion runs in the background and must not block
  # real-time API transactions. If a row is locked by an active request,
  # we fail fast and the next deletion step retries.
  # 15min statement: cascading deletes (events, statistics, visitors) can touch
  # millions of rows per table for large tenants.
  def with_local_timeouts(lock: "2s", statement: "#{STATEMENT_TIMEOUT.in_minutes.to_i}min")
    raise ArgumentError, "invalid lock_timeout: #{lock}" unless lock.match?(VALID_TIMEOUT)
    raise ArgumentError, "invalid statement_timeout: #{statement}" unless statement.match?(VALID_TIMEOUT)

    ActiveRecord::Base.with_connection do |conn|
      ActiveRecord::Base.transaction do
        conn.execute("SET LOCAL lock_timeout = '#{lock}'")
        conn.execute("SET LOCAL statement_timeout = '#{statement}'")
        yield
      end
    end
  end

  # Build a safe Postgres array literal with explicit type cast.
  # Example: pg_array_literal([1,2,3], cast: "bigint") => "ARRAY[1,2,3]::bigint[]"
  def pg_array_literal(values, cast: "bigint")
    ActiveRecord::Base.with_connection do |conn|
      inner = Array(values).map { |v| conn.quote(v) }.join(",")
      "ARRAY[#{inner}]::#{cast}[]"
    end
  end

  # Convenience: generate "col = ANY(ARRAY[...]::<cast>[])"
  def sql_any_array(col_sql, values, cast:)
    "#{col_sql} = ANY(#{pg_array_literal(values, cast: cast)})"
  end

  # Map an AR column type to a sensible Postgres array cast
  # Used for the ANY(ARRAY[..]) predicate.
  def sql_array_cast_for(model_class, column)
    col = model_class.columns_hash[column.to_s]
    return "bigint" unless col
    case col.sql_type_metadata.type
    when :bigint, :integer then "bigint"
    when :uuid              then "uuid"
    when :string            then "text"
    when :datetime, :timestamp then "timestamptz"
    when :date              then "date"
    when :boolean           then "boolean"
    else "bigint"
    end
  end

  # Decide how to batch-delete:
  #  - if model has PK => use in_batches(of:).
  #  - if no PK (common for rollups/views) => use CTE over ctid.
  # IMPORTANT: we DO NOT pass array binds to exec_delete.
  # `where_sql` must be a complete boolean expression (no binds).
  def batch_delete_by(scope:, table_name:, where_sql:, batch_size: BATCH_SIZE)
    klass = scope.klass

    if klass.primary_key.present?
      with_local_timeouts do
        scope.in_batches(of: batch_size, &:delete_all)
      end
    else
      with_local_timeouts do
        conn = ActiveRecord::Base.lease_connection
        loop do
          sql = <<~SQL
            WITH chunk AS (
              SELECT ctid
              FROM #{table_name}
              WHERE #{where_sql}
              LIMIT #{Integer(batch_size)}
            )
            DELETE FROM #{table_name} t
            USING chunk
            WHERE t.ctid = chunk.ctid
          SQL
          deleted = conn.exec_delete(sql, "BatchDelete")
          break if deleted.zero?

          # sleep(0.02) # optional throttle
        end
      end
    end
  end

  # -----------------------------
  # Deletion routines
  # -----------------------------

  def remove_notifications_for_projects(project_ids)
    conn = ActiveRecord::Base.connection
    # The legacy tables outlive their models by one release; their rows still belong to the instance.
    return if project_ids.empty? || !conn.table_exists?(:notifications)

    owned = "SELECT id FROM notifications WHERE project_id IN (#{project_ids.map { |id| Integer(id) }.join(', ')})"
    with_local_timeouts do
      conn.execute("DELETE FROM notification_targets WHERE notification_id IN (#{owned})")
      # One row per visitor and message, so this is the table that can be large: it goes in pages.
      page = "SELECT id FROM notification_messages WHERE notification_id IN (#{owned}) LIMIT #{BATCH_SIZE}"
      nil until conn.exec_delete("DELETE FROM notification_messages WHERE id IN (#{page})").zero?
      conn.execute("DELETE FROM notifications WHERE id IN (#{owned})")
    end
  end

  def remove_iap_webhook_messages_for_projects(project_ids)
    scope = IapWebhookMessage.unscoped.where(project_id: project_ids)
    table = IapWebhookMessage.table_name
    cast  = sql_array_cast_for(IapWebhookMessage, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_installed_apps_for_projects(project_ids)
    scope = InstalledApp.unscoped.where(project_id: project_ids)
    table = InstalledApp.table_name
    cast  = sql_array_cast_for(InstalledApp, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_purchase_events_for_projects(project_ids)
    scope = PurchaseEvent.unscoped.where(project_id: project_ids)
    table = PurchaseEvent.table_name
    cast  = sql_array_cast_for(PurchaseEvent, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_visitor_last_visits_for_projects(project_ids)
    scope = VisitorLastVisit.unscoped.where(project_id: project_ids)
    table = VisitorLastVisit.table_name
    cast  = sql_array_cast_for(VisitorLastVisit, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_device_last_seens_for_projects(project_ids)
    log "removing device last seens for projects"
    scope = DeviceLastSeen.unscoped.where(project_id: project_ids)
    cast  = sql_array_cast_for(DeviceLastSeen, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: DeviceLastSeen.table_name, where_sql: where_sql, batch_size: BATCH_SIZE)
    log "device last seens removed"
  end

  def remove_custom_hostnames_for_projects(project_ids)
    CustomHostname.unscoped.where(project_id: project_ids).find_each(batch_size: SUB_BATCH_SIZE) do |custom_hostname|
      next if CustomDomainProvisioningService.destroy(custom_hostname)

      raise "Cloudflare custom hostname delete failed for custom_hostname_id=#{custom_hostname.id}"
    end
  end

  def remove_smart_banners_for_projects(project_ids)
    log "removing smart banners for projects"
    banner_ids = SmartBanner.where(project_id: project_ids).pluck(:id)
    unless banner_ids.empty?
      with_local_timeouts do
        SmartBannerLink.where(smart_banner_id: banner_ids).in_batches(of: BATCH_SIZE).delete_all
        SmartBanner.where(id: banner_ids).delete_all
      end
    end
    log "smart banners removed"
  end

  def remove_links_for_projects(project_ids)
    domain_ids = Domain.where(project_id: project_ids).pluck(:id)

    with_local_timeouts do
      Link.unscoped.where(domain_id: domain_ids).in_batches(of: BATCH_SIZE) do |batch|
        ids = batch.pluck(:id)
        ids.each_slice(SUB_BATCH_SIZE) do |slice|
          CustomRedirect.unscoped.where(link_id: slice).delete_all
          # Explicit (not via the actions FK cascade) to keep the lock profile flat
          Action.unscoped.where(link_id: slice).delete_all
        end
        batch.delete_all
      end
    end

    # Domains after links
    scope = Domain.unscoped.where(project_id: project_ids)
    table = Domain.table_name
    cast  = sql_array_cast_for(Domain, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_campaigns_for_projects(project_ids)
    scope = Campaign.unscoped.where(project_id: project_ids)
    table = Campaign.table_name
    cast  = sql_array_cast_for(Campaign, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_redirect_configs_for_projects(project_ids)
    ids = RedirectConfig.where(project_id: project_ids).pluck(:id)
    with_local_timeouts do
      Redirect.unscoped.where(redirect_config_id: ids).delete_all
      RedirectConfig.unscoped.where(project_id: project_ids).delete_all
    end
  end

  # delete_all skips the push configs' cleanup, which would leave their credentials live in rpush.
  def remove_rpush_apps(ios_configuration_ids, android_configuration_ids)
    names = IosPushConfiguration.unscoped.where(ios_configuration_id: ios_configuration_ids).pluck(:name)
                                .flat_map { |name| ["#{name}-development", "#{name}-production"] }
    names += AndroidPushConfiguration.unscoped.where(android_configuration_id: android_configuration_ids).pluck(:name)
    Rpush::Client::ActiveRecord::App.where(name: names).find_each { |app| RpushService.remove_app(app) }
  end

  def remove_applications_for_instance(instance_id)
    application_ids = Application.where(instance_id: instance_id).pluck(:id)

    ios_configuration_ids = IosConfiguration.where(application_id: application_ids).pluck(:id)
    android_configuration_ids = AndroidConfiguration.where(application_id: application_ids).pluck(:id)
    remove_rpush_apps(ios_configuration_ids, android_configuration_ids)
    with_local_timeouts do
      IosPushConfiguration.unscoped.where(ios_configuration_id: ios_configuration_ids).delete_all
      IosServerApiKey.unscoped.where(ios_configuration_id: ios_configuration_ids).delete_all
      IosConfiguration.unscoped.where(application_id: application_ids).delete_all
    end

    with_local_timeouts do
      AndroidPushConfiguration.unscoped.where(android_configuration_id: android_configuration_ids).delete_all
      AndroidServerApiKey.unscoped.where(android_configuration_id: android_configuration_ids).delete_all
      AndroidConfiguration.unscoped.where(application_id: application_ids).delete_all
    end

    desktop_configuration_ids = DesktopConfiguration.where(application_id: application_ids).pluck(:id)
    with_local_timeouts do
      DesktopConfiguration.unscoped.where(id: desktop_configuration_ids).delete_all
    end

    web_configuration_ids = WebConfiguration.where(application_id: application_ids).pluck(:id)
    with_local_timeouts do
      WebConfigurationLinkedDomain.unscoped.where(web_configuration_id: web_configuration_ids).delete_all
      WebConfiguration.unscoped.where(application_id: application_ids).delete_all
    end

    with_local_timeouts do
      Application.unscoped.where(id: application_ids).delete_all
    end
  end

  def remove_visitors_for_projects(project_ids)
    scope = Visitor.unscoped.where(project_id: project_ids)
    table = Visitor.table_name
    cast  = sql_array_cast_for(Visitor, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_project_daily_active_users_for_projects(project_ids)
    scope = ProjectDailyActiveUser.unscoped.where(project_id: project_ids)
    table = ProjectDailyActiveUser.table_name
    cast  = sql_array_cast_for(ProjectDailyActiveUser, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_visitor_daily_statistics_for_projects(project_ids)
    scope = VisitorDailyStatistic.unscoped.where(project_id: project_ids)
    table = VisitorDailyStatistic.table_name
    cast  = sql_array_cast_for(VisitorDailyStatistic, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_link_daily_statistics_for_projects(project_ids)
    scope = LinkDailyStatistic.unscoped.where(project_id: project_ids)
    table = LinkDailyStatistic.table_name
    cast  = sql_array_cast_for(LinkDailyStatistic, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end

  def remove_screen_aliases_and_dashboards_for_projects(project_ids)
    with_local_timeouts do
      ScreenAlias.unscoped.where(project_id: project_ids).delete_all
      Dashboard.unscoped.where(project_id: project_ids).delete_all
    end
  end

  def remove_daily_project_metrics_for_projects(project_ids)
    scope = DailyProjectMetric.unscoped.where(project_id: project_ids)
    table = DailyProjectMetric.table_name
    cast  = sql_array_cast_for(DailyProjectMetric, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end
end
