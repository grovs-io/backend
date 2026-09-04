class VisitorDailyStatistic < ApplicationRecord
  belongs_to :visitor

  attribute :views,        :integer, default: 0
  attribute :opens,        :integer, default: 0
  attribute :installs,     :integer, default: 0
  attribute :reinstalls,   :integer, default: 0
  attribute :time_spent,   :integer, default: 0
  attribute :revenue,      :integer, default: 0
  attribute :reactivations,:integer, default: 0
  attribute :app_opens,    :integer, default: 0
  attribute :user_referred,:integer, default: 0

  scope :within_range, lambda { |start_date, end_date|
    where(event_date: start_date..end_date)
  }

  METRIC_COLUMNS = %i[
    views opens installs reinstalls time_spent revenue
    reactivations app_opens user_referred
  ].freeze

  def self.merge_visitors!(from_id:, to_id:)
    raise ArgumentError, "from and to must differ" if from_id.to_i == to_id.to_i

    # Atomic move: DELETE..RETURNING feeding the upsert means concurrent merges
    # can never delete a row without copying it. ORDER BY conflict key (deadlock rule).
    # NULLIF: rows the target itself referred must not become self-referrals.
    sanitized = sanitize_sql_array([<<~SQL, from_id, to_id, to_id])
      WITH moved AS (
        DELETE FROM visitor_daily_statistics
        WHERE visitor_id = ?
        RETURNING project_id, event_date, platform, invited_by_id,
                  views, opens, installs, reinstalls, time_spent,
                  revenue, reactivations, app_opens, user_referred
      )
      INSERT INTO visitor_daily_statistics
        (visitor_id, project_id, event_date, platform, invited_by_id,
         views, opens, installs, reinstalls, time_spent,
         revenue, reactivations, app_opens, user_referred,
         created_at, updated_at)
      SELECT
        ?, project_id, event_date, platform, NULLIF(invited_by_id, ?),
        views, opens, installs, reinstalls, time_spent,
        revenue, reactivations, app_opens, user_referred,
        NOW(), NOW()
      FROM moved
      ORDER BY project_id, event_date, platform
      ON CONFLICT (project_id, visitor_id, event_date, platform)
      DO UPDATE SET
        views         = COALESCE(visitor_daily_statistics.views, 0)         + COALESCE(EXCLUDED.views, 0),
        opens         = COALESCE(visitor_daily_statistics.opens, 0)         + COALESCE(EXCLUDED.opens, 0),
        installs      = COALESCE(visitor_daily_statistics.installs, 0)      + COALESCE(EXCLUDED.installs, 0),
        reinstalls    = COALESCE(visitor_daily_statistics.reinstalls, 0)    + COALESCE(EXCLUDED.reinstalls, 0),
        time_spent    = COALESCE(visitor_daily_statistics.time_spent, 0)    + COALESCE(EXCLUDED.time_spent, 0),
        revenue       = COALESCE(visitor_daily_statistics.revenue, 0)       + COALESCE(EXCLUDED.revenue, 0),
        reactivations = COALESCE(visitor_daily_statistics.reactivations, 0) + COALESCE(EXCLUDED.reactivations, 0),
        app_opens     = COALESCE(visitor_daily_statistics.app_opens, 0)     + COALESCE(EXCLUDED.app_opens, 0),
        user_referred = COALESCE(visitor_daily_statistics.user_referred, 0) + COALESCE(EXCLUDED.user_referred, 0),
        invited_by_id = COALESCE(visitor_daily_statistics.invited_by_id, EXCLUDED.invited_by_id),
        updated_at    = NOW()
    SQL
    connection.execute(sanitized)
  end

  def self.aggregate_by_visitor(start_date:, end_date:, sort_by: :views)
    raise ArgumentError, "Invalid sort key" unless METRIC_COLUMNS.include?(sort_by.to_sym)

    t = arel_table
    within_range(start_date, end_date)
      .group(:visitor_id)
      .select(
        :visitor_id,
        *METRIC_COLUMNS.map { |col| t[col].sum.as(col.to_s) }
      )
      .order(t[sort_by.to_sym].sum.desc)
  end
end
