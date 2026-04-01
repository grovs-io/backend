# app/jobs/delete_instance_job.rb
class DeleteInstanceJob
  include Sidekiq::Worker
  sidekiq_options queue: :maintenance, retry: 2

  BATCH_SIZE     = 50_000
  SUB_BATCH_SIZE = 10_000

  def perform(instance_id)
    instance = Instance.find_by(id: instance_id)
    unless instance
      log "Instance with ID #{instance_id} not found, skipping deletion.", level: :warn
      return
    end

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

    # Visitor last visits (FK to links, visitors, projects — must go before all three)
    log "removing visitor last visits for projects"
    remove_visitor_last_visits_for_projects(project_ids)
    log "visitor last visits removed"

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

    log "Removing projects"
    Project.unscoped.where(id: project_ids).delete_all
    log "projects removed"

    EnterpriseSubscription.unscoped.where(instance_id: instance.id).delete_all
    log "enterprise subscriptions removed"

    instance.destroy!
    log "instance #{instance.id} destroyed"

  rescue StandardError => e
    log "ERROR: #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}", level: :error
    raise
  end

  private

  # -----------------------------
  # Logging
  # -----------------------------

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
  def with_local_timeouts(lock: "2s", statement: "15min")
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
    with_local_timeouts do
      Notification.unscoped.where(project_id: project_ids).in_batches(of: BATCH_SIZE) do |batch|
        ids = batch.pluck(:id)

        ids.each_slice(SUB_BATCH_SIZE) do |slice|
          NotificationTarget.unscoped.where(notification_id: slice).delete_all
          NotificationMessage.unscoped.where(notification_id: slice).delete_all
        end

        batch.delete_all
      end
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

  def remove_links_for_projects(project_ids)
    domain_ids = Domain.where(project_id: project_ids).pluck(:id)

    with_local_timeouts do
      Link.unscoped.where(domain_id: domain_ids).in_batches(of: BATCH_SIZE) do |batch|
        ids = batch.pluck(:id)
        ids.each_slice(SUB_BATCH_SIZE) do |slice|
          CustomRedirect.unscoped.where(link_id: slice).delete_all
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

  def remove_applications_for_instance(instance_id)
    application_ids = Application.where(instance_id: instance_id).pluck(:id)

    # iOS
    ios_configuration_ids = IosConfiguration.where(application_id: application_ids).pluck(:id)
    with_local_timeouts do
      IosPushConfiguration.unscoped.where(ios_configuration_id: ios_configuration_ids).delete_all
      IosServerApiKey.unscoped.where(ios_configuration_id: ios_configuration_ids).delete_all
      IosConfiguration.unscoped.where(application_id: application_ids).delete_all
    end

    # Android
    android_configuration_ids = AndroidConfiguration.where(application_id: application_ids).pluck(:id)
    with_local_timeouts do
      AndroidPushConfiguration.unscoped.where(android_configuration_id: android_configuration_ids).delete_all
      AndroidServerApiKey.unscoped.where(android_configuration_id: android_configuration_ids).delete_all
      AndroidConfiguration.unscoped.where(application_id: application_ids).delete_all
    end

    # Desktop
    desktop_configuration_ids = DesktopConfiguration.where(application_id: application_ids).pluck(:id)
    with_local_timeouts do
      DesktopConfiguration.unscoped.where(id: desktop_configuration_ids).delete_all
    end

    # Web
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

  def remove_daily_project_metrics_for_projects(project_ids)
    scope = DailyProjectMetric.unscoped.where(project_id: project_ids)
    table = DailyProjectMetric.table_name
    cast  = sql_array_cast_for(DailyProjectMetric, :project_id)
    where_sql = sql_any_array("project_id", project_ids, cast: cast)

    batch_delete_by(scope: scope, table_name: table, where_sql: where_sql, batch_size: BATCH_SIZE)
  end
end