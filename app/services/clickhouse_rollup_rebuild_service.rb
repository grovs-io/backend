# frozen_string_literal: true

# Bounded, idempotent rebuild of the exact CH rollups from the DEDUPED
# events store. One shared mechanism reused by all three rollups
# (project / link / visitor). Per rollup, per dirty YYYYMM partition:
#   1. recompute the whole partition into a staging table (deduped via FINAL),
#   2. atomically REPLACE PARTITION into the live rollup,
#   3. drop the staging table.
# Reads never see a half-built partition, and a duplicate row in canonical can
# never inflate a rollup (FINAL collapses by event_id before aggregation).
# Rebuilds are partition-scoped (toYYYYMM), so they are never O(all-history).
# rubocop:disable Metrics/ModuleLength -- catalog of independent rollup definitions
module ClickhouseRollupRebuildService
  DIRTY_KEY = "clickhouse:rollup:dirty_partitions"

  # Lock TTL must outlive the slowest single-partition rebuild (CREATE staging +
  # INSERT...SELECT + REPLACE PARTITION). 300s is far beyond a normal rebuild.
  LOCK_TTL = 300
  # Clamped under LOCK_TTL: a query outliving its lock lets a duplicate rebuild start.
  REBUILD_MAX_EXECUTION_SECONDS =
    [Integer(ENV.fetch("CLICKHOUSE_ROLLUP_MAX_EXECUTION_SECONDS", 240)), LOCK_TTL - 60].min
  # Uncapped, each rebuild INSERT grabs one thread per core — concurrent lanes exhausted CH's pool.
  REBUILD_MAX_THREADS = Integer(ENV.fetch("CLICKHOUSE_ROLLUP_MAX_THREADS", 16)).clamp(1, 64)
  LOCK_PREFIX = "clickhouse:rollup:rebuild"

  # CAS-unlock so a TTL-expired holder can't stomp a successor's lock.
  RELEASE_LUA = <<~LUA
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  LUA

  # The dirty-set and rebuild-lock Redis keys are scoped by the active ClickHouse
  # database. In production there is a single database, so cross-worker dedup and
  # locking are unchanged. In tests each class gets its own CH database while
  # sharing the per-worker Redis, so scoping prevents one class's lock/dirty state
  # from making another class's rebuild silently skip (empty rollup).
  def self.dirty_key
    "#{DIRTY_KEY}:#{Clickhouse.default_database}"
  end

  def self.lock_key_for(rollup_key, partition)
    "#{LOCK_PREFIX}:#{Clickhouse.default_database}:#{rollup_key}:#{partition}"
  end

  # The full event-countable metric set, in canonical order. time_spent sums
  # engagement_time; everything else is a count of that event_type. revenue is
  # intentionally absent everywhere — it comes from the purchase pipeline, not
  # events (purchase_* rollups cover it separately).
  ALL_METRIC_EXPRS = {
    views: "countIf(event_type = 'view') AS views",
    opens: "countIf(event_type = 'open') AS opens",
    installs: "countIf(event_type = 'install') AS installs",
    reinstalls: "countIf(event_type = 'reinstall') AS reinstalls",
    time_spent: "sumIf(engagement_time, event_type = 'time_spent') AS time_spent",
    reactivations: "countIf(event_type = 'reactivation') AS reactivations",
    app_opens: "countIf(event_type = 'app_open') AS app_opens",
    user_referred: "countIf(event_type = 'user_referred') AS user_referred"
  }.freeze

  # The project rollup mirrors ONLY the directly-countable columns that exist in
  # PG daily_project_metrics: views/opens/installs/reinstalls/app_opens. PG has no
  # time_spent/reactivations/user_referred column on that table; the other PG
  # columns (new_users, organic_users, referred_users, revenue, …) are
  # derived/attribution/purchase and land in Phase 5, not here.
  PROJECT_METRIC_EXPRS = ALL_METRIC_EXPRS.values_at(
    :views, :opens, :installs, :reinstalls, :app_opens
  ).join(",\n          ").freeze

  # link & visitor rollups mirror the full event-countable set (their PG tables
  # do carry time_spent/reactivations/user_referred).
  METRIC_EXPRS = ALL_METRIC_EXPRS.values.join(",\n          ").freeze

  # Phase 4: the visitor identity-map (merged→survivor) resolved BEFORE aggregation.
  # Every group/uniqExact/count over visitor_id in the rebuild uses this expression,
  # so a merged visitor's pre-merge canonical rows roll up under the survivor (counted
  # once, under the survivor) and are never double-counted. Un-mapped visitors pass
  # through unchanged: the LEFT JOIN (injected by FROM_WITH_IDENTITY_MAP) yields 0 for
  # them, and `if(mapped > 0, mapped, visitor_id)` falls back to the raw id.
  #
  # The map is path-compressed (A->B->C stored as A->C, B->C), so a single
  # non-recursive JOIN resolves to the FINAL survivor.
  IDENTITY_MAP_ALIAS = "vim"

  def self.effective_visitor_id_expr
    "if(#{IDENTITY_MAP_ALIAS}.to_visitor_id > 0, #{IDENTITY_MAP_ALIAS}.to_visitor_id, events.visitor_id)"
  end

  # Phase 5 — per-visitor source classification, derived ONLY from the FROZEN
  # event-time fields (campaign_id, sdk_generated, link_visitor_id, link_id) via the
  # single SourceTaxonomy definition, so CH attribution reconciles with the existing
  # source dashboards. Install types and the "touch" predicate are defined once here.
  def self.source_expr
    Analytics::SourceTaxonomy.expr("events")
  end

  INSTALL_TYPES_SQL = "('install', 'reinstall')"

  # Event types that create PG visitor_daily_statistics rows (billable/countable set).
  COUNTABLE_TYPES_SQL =
    "('view','open','install','reinstall','time_spent','reactivation','app_open','user_referred')"

  # A "link touch" / first-touch-eligible event is any NON-ORGANIC event under the
  # taxonomy — campaign, referral, api_link OR plain link. Deriving it as
  # `source_expr != 'organic'` keeps it provably consistent with SourceTaxonomy
  # (a campaign event has campaign_id>0 but may carry link_id=0, yet is still an
  # attributable touch). first_touch_source/last_touch_source/has_link all key off this.
  #
  # PRODUCT / ANALYTICS DESIGN NOTE (MUST be confirmed before Phase 6 cutover):
  # first_touch_source / has_link (and the install/first/last resolvers built on them)
  # COUNT campaigns AND sdk-referrals as link touches EVEN WHEN link_id = 0, because the
  # single Analytics::SourceTaxonomy keys "is this an attributable touch?" off the source
  # bucket (campaign_id>0, sdk_generated+link_visitor_id, link_id>0), NOT off link_id alone.
  # This is consistent with the EXISTING source dashboards. If PRODUCT/ANALYTICS want a
  # stricter "must have a materialized link" definition, this predicate (and the migration's
  # has_link column) must change together. Do not silently diverge the two.
  def self.has_link_predicate
    "(#{source_expr} != 'organic')"
  end

  # FROM clause that LEFT JOINs the path-compressed identity map onto canonical,
  # keyed (project_id, visitor_id). FINAL collapses the ReplacingMergeTree to the
  # latest alias per (project, from_visitor). Un-mapped rows get to_visitor_id = 0.
  FROM_WITH_IDENTITY_MAP = <<~SQL.strip
    FROM events FINAL
    LEFT JOIN (
      SELECT project_id, from_visitor_id, to_visitor_id
      FROM visitor_identity_map FINAL
    ) AS #{IDENTITY_MAP_ALIAS}
    ON events.project_id = #{IDENTITY_MAP_ALIAS}.project_id
    AND events.visitor_id = #{IDENTITY_MAP_ALIAS}.from_visitor_id
  SQL

  # Per-rollup config: the target table, its extra key columns (beyond
  # date/platform), and the per-partition recompute SELECT against canonical.
  #
  # Two families share this mechanism:
  #   * the exact TOTALS rollups (project/link/visitor _metrics_daily) — plain
  #     MergeTree, denormalized metric columns;
  #   * the exact BREAKDOWN rollups (project_daily/link_daily/visitor_daily/
  #     project_country_daily/project_version_daily/project_source_daily/
  #     project_property_daily/billing_active_visitors_daily) — the SAME
  #     Aggregating/Summing tables the dashboards already read, but recomputed
  #     from canonical FINAL (was MV-fed from plain events). Recomputing replaces
  #     the MVs: MVs fire pre-dedup and are merge-blind, so they double-count
  #     retries and ignore visitor merges; the rebuild collapses replays (FINAL)
  #     and resolves the identity map (EFFECTIVE_VISITOR) before aggregating.
  #     Every visitors_state here is therefore merge-aware — an intended, exact
  #     correction over the MV values (billing counts included).
  ROLLUPS = {
    project: {
      table: "project_metrics_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          toDate(created_at) AS event_date,
          platform,
          #{PROJECT_METRIC_EXPRS},
          uniqExact(EFFECTIVE_VISITOR) AS unique_visitors,
          uniqExact(device_id) AS unique_devices
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
        GROUP BY project_id, event_date, platform
      SQL
    },
    link: {
      table: "link_metrics_daily",
      select: <<~SQL
        SELECT
          project_id,
          link_id,
          toDate(created_at) AS event_date,
          platform,
          #{METRIC_EXPRS}
        FROM events FINAL
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND link_id > 0
        GROUP BY project_id, link_id, event_date, platform
      SQL
    },
    visitor: {
      table: "visitor_metrics_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          EFFECTIVE_VISITOR AS visitor_id,
          toDate(created_at) AS event_date,
          platform,
          #{METRIC_EXPRS},
          max(inviter_id) AS inviter_id
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND EFFECTIVE_VISITOR > 0
        GROUP BY project_id, visitor_id, event_date, platform
      SQL
    },
    # Phase 5 — last-touch-source DAILY SNAPSHOT. Per (project, effective-visitor, day),
    # the source of that day's LAST link-touch. The as-of read merges all rows up to the
    # range end. AS-OF CONTRACT (precise): a range's answer is a function of events DATED
    # within/up-to the range end — an event dated AFTER the range never changes it, but a
    # late event dated INSIDE the range legitimately does (correct as-of). A touched day's
    # row recomputes deterministically (canonical immutable; survivor partitions recompute
    # identically), so re-running the same query over the same dated events is byte-stable.
    # Partition-scoped.
    last_touch: {
      table: "visitor_last_touch_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          EFFECTIVE_VISITOR AS visitor_id,
          toDate(created_at) AS event_date,
          argMaxIfState(SOURCE_EXPR, (created_at, event_id), HAS_LINK) AS last_touch_source,
          maxIfState(created_at, HAS_LINK) AS last_touch_ts,
          maxIfState(toUInt8(1), HAS_LINK) AS has_link
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND EFFECTIVE_VISITOR > 0
        GROUP BY project_id, visitor_id, event_date
      SQL
    },
    # Phase 5 — exact per-day visitor breakdown by TIME-VARYING dimensions
    # (version / country / platform). One (dimension, value) row-set per day; exact
    # via uniqExactState. arrayJoin emits one logical row per dimension per event.
    dimension: {
      table: "visitor_dimension_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          toDate(created_at) AS event_date,
          dim.1 AS dimension,
          dim.2 AS value,
          uniqExactState(EFFECTIVE_VISITOR) AS visitors_state
        FROM_WITH_IDENTITY_MAP
        ARRAY JOIN [
          ('version', app_version),
          ('country', country),
          ('platform', platform)
        ] AS dim
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND EFFECTIVE_VISITOR > 0
        GROUP BY project_id, event_date, dimension, value
      SQL
    },

    # --- BREAKDOWN rollups (was MV-fed from plain events; now canonical rebuilds).
    # Each mirrors its old MV's SELECT/schema EXACTLY, changing only: FROM plain
    # events -> canonical FINAL (+ identity map), and visitor_id -> EFFECTIVE_VISITOR
    # for merge-aware visitor uniqueness. Same target table, same reader.

    # -> project_daily (AggregatingMergeTree): per event_type x platform counts,
    # engagement, uniq visitors + devices.
    project_breakdown: {
      table: "project_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          toDate(created_at) AS event_date,
          event_type,
          platform,
          count()               AS cnt,
          sum(engagement_time)  AS total_engagement_time,
          uniqState(EFFECTIVE_VISITOR) AS visitors_state,
          uniqState(device_id)  AS devices_state
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
        GROUP BY project_id, event_date, event_type, platform
      SQL
    },

    # -> link_daily (SummingMergeTree): per link/campaign/event_type/platform
    # counts + engagement. No visitor state, so no identity map needed.
    link_breakdown: {
      table: "link_daily",
      select: <<~SQL
        SELECT
          project_id,
          link_id,
          campaign_id,
          toDate(created_at) AS event_date,
          event_type,
          platform,
          count()              AS cnt,
          sum(engagement_time) AS total_engagement_time
        FROM events FINAL
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND link_id != 0
        GROUP BY project_id, link_id, campaign_id, event_date, event_type, platform
      SQL
    },

    # -> visitor_daily (AggregatingMergeTree): per visitor/event_type/platform
    # counts, engagement, inviter.
    visitor_breakdown: {
      table: "visitor_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          EFFECTIVE_VISITOR AS visitor_id,
          toDate(created_at) AS event_date,
          event_type,
          platform,
          count()              AS cnt,
          sum(engagement_time) AS total_engagement_time,
          max(inviter_id)      AS inviter_id_state
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND EFFECTIVE_VISITOR > 0
        GROUP BY project_id, visitor_id, event_date, event_type, platform
      SQL
    },

    # -> link_session_daily. The only rollup sourced from session_summary (FINAL: RMT).
    link_sessions: {
      table: "link_session_daily",
      select: <<~SQL
        SELECT
          project_id,
          link_id,
          event_date,
          platform,
          count() AS sessions,
          sum(duration_ms) AS duration_ms_sum,
          countIf(duration_ms > 0) AS engaged_sessions,
          sumIf(duration_ms, duration_ms > 0) AS engaged_duration_ms_sum
        FROM session_summary FINAL
        WHERE toYYYYMM(event_date) = {partition:UInt32}
          AND link_id != 0
        GROUP BY project_id, link_id, event_date, platform
      SQL
    },

    # -> project_country_daily (AggregatingMergeTree).
    country: {
      table: "project_country_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          toDate(created_at) AS event_date,
          country,
          event_type,
          platform,
          count()               AS cnt,
          uniqState(EFFECTIVE_VISITOR) AS visitors_state
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
        GROUP BY project_id, event_date, country, event_type, platform
      SQL
    },

    # -> project_version_daily (AggregatingMergeTree). first_seen is a per-day min;
    # the reader takes min across partitions, so min-of-per-partition-mins = the
    # true global release date (partition-scoped rebuild preserves it).
    version: {
      table: "project_version_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          toDate(created_at) AS event_date,
          app_version,
          platform,
          count()               AS cnt,
          uniqState(EFFECTIVE_VISITOR) AS visitors_state,
          min(created_at)       AS first_seen
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
        GROUP BY project_id, event_date, app_version, platform
      SQL
    },

    # -> project_source_daily (AggregatingMergeTree). SOURCE_EXPR is the single
    # SourceTaxonomy classifier (identical labels to the old MV's expression).
    source: {
      table: "project_source_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          toDate(created_at) AS event_date,
          SOURCE_EXPR AS source,
          platform,
          count()               AS cnt,
          uniqState(EFFECTIVE_VISITOR) AS visitors_state
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
        GROUP BY project_id, event_date, source, platform
      SQL
    },

    # -> project_property_daily (AggregatingMergeTree). Curated plan/tier buckets.
    # canonical `properties` is a JSON column, so read via subcolumn cast
    # (CAST(properties.`key` AS String)) instead of the MV's JSONExtractString.
    property: {
      table: "project_property_daily",
      select: <<~SQL
        SELECT
          project_id,
          event_date,
          property_key,
          property_value,
          event_type,
          platform,
          count()               AS cnt,
          uniqState(visitor_id) AS visitors_state
        FROM (
          SELECT
            events.project_id AS project_id,
            toDate(created_at) AS event_date,
            event_type,
            platform,
            EFFECTIVE_VISITOR AS visitor_id,
            arrayJoin([
              tuple('plan', CAST(properties.`plan` AS String)),
              tuple('tier', CAST(properties.`tier` AS String))
            ]) AS property_tuple,
            property_tuple.1 AS property_key,
            property_tuple.2 AS property_value
          FROM_WITH_IDENTITY_MAP
          WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
        )
        WHERE property_value != ''
        GROUP BY project_id, event_date, property_key, property_value, event_type, platform
      SQL
    },

    # -> billing_active_visitors_daily (AggregatingMergeTree, uniqExact). Now
    # merge-aware (EFFECTIVE_VISITOR): a web->mobile merge counts one MAU, not two.
    billing: {
      table: "billing_active_visitors_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          toDate(created_at) AS event_date,
          uniqExactState(EFFECTIVE_VISITOR) AS visitors_state
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND EFFECTIVE_VISITOR != 0
          AND event_type IN COUNTABLE_TYPES
        GROUP BY project_id, event_date
      SQL
    },

    # -> visitor_first_seen_daily. Platform-grained + normalized like Device#platform_for_metrics;
    # install min counts 'install' only (PG installs column ignores reinstalls);
    # reader takes min-of-per-partition-mins for the true global first-seen.
    first_seen: {
      table: "visitor_first_seen_daily",
      select: <<~SQL
        SELECT
          events.project_id AS project_id,
          if(platform IN ('ios', 'android'), platform, 'web') AS platform,
          EFFECTIVE_VISITOR AS visitor_id,
          toStartOfMonth(toDate(created_at)) AS event_month,
          minState(created_at) AS first_seen_state,
          minIfState(created_at, event_type = 'install') AS install_seen_state
        FROM_WITH_IDENTITY_MAP
        WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
          AND EFFECTIVE_VISITOR > 0
          AND event_type IN COUNTABLE_TYPES
        GROUP BY project_id, platform, visitor_id, event_month
      SQL
    }
  }.freeze

  # --- dirty-partition tracking + watermark -------------------------------

  # Best-effort. Dirty-tracking is an OPTIMIZATION, not a guarantee: a failure here
  # is emitted (log + metric) so persistent failures are visible, but the watermark
  # window (rebuild_all_dirty) and explicit rebuild_partition_range are the real
  # correctness guarantees — a partition that never got marked dirty is still
  # rebuilt by the watermark if recent; older dirty partitions are absorbed by the
  # daily rebuild_stale_dirty lane, arbitrary ones by the range entry point.
  def self.mark_dirty(event_date)
    REDIS.with { |c| c.sadd?(dirty_key, partition_for(event_date)) }
  rescue StandardError => e
    Rails.logger.error(
      "ClickhouseRollupRebuildService#mark_dirty FAILED for #{event_date} — " \
      "#{e.class}: #{e.message}. metric=clickhouse_rollup_mark_dirty_failed"
    )
    nil
  end

  def self.dirty_partitions
    REDIS.with { |c| c.smembers(dirty_key) }
  end

  # Bounds the partition-discovery query. visitor_id is NOT the leading ORDER BY
  # key (only a minmax data-skipping index on events), so for a
  # pathological high-volume visitor this DISTINCT could degrade toward a project
  # scan. Both an HTTP read-timeout AND a CH-side max_execution_time cap it so it
  # can never hang the merge; on breach we fall back to the watermark window.
  # Scaling assumption: a single visitor's canonical footprint is small relative
  # to a project's; if that ever stops holding, promote visitor_id in ORDER BY.
  DISCOVERY_TIMEOUT_SECONDS = Integer(ENV.fetch("CLICKHOUSE_VISITOR_DISCOVERY_TIMEOUT", 5))

  # Phase 4: mark every YYYYMM partition that holds canonical events for a visitor
  # (resolved through the identity map) dirty — recent ones recomputed by the next
  # 10-min pass, older ones by the daily catch-up. Used by visitor merge: the events
  # span whichever months they occurred (possibly old partitions outside the
  # watermark window), so we discover them from canonical rather than guessing.
  # Best-effort / rescued — a CH or Redis hiccup must not break the PG merge. On a
  # discovery-query failure/timeout we still mark the watermark window dirty so
  # recent data is rebuilt, and log a metric.
  # Months of the id's EFFECTIVE identity — a long-merged id yields [] post-rebuild; pass the survivor too.
  def self.mark_dirty_for_visitor(project_id, visitor_id)
    return unless Clickhouse.enabled?

    partitions = visitor_partitions(project_id, [visitor_id])

    REDIS.with { |c| c.sadd?(dirty_key, partitions) } if partitions.any?
    partitions
  rescue StandardError => e
    Rails.logger.error(
      "ClickhouseRollupRebuildService#mark_dirty_for_visitor FAILED for project " \
      "#{project_id} visitor #{visitor_id} — #{e.class}: #{e.message}. " \
      "metric=clickhouse_rollup_visitor_discovery_failed — falling back to watermark window"
    )
    mark_watermark_window_dirty
  end

  # Explicit visitor-merge acquisition repair. The normal scheduler path stays
  # partition-local and project-wide; merge repair is tighter and visitor-scoped:
  # after the identity alias exists, discover the raw partitions for the merged
  # and survivor ids, then insert acquisition states for only those raw visitors.
  def self.repair_acquisition_for_visitor_merge(project_id, merged_visitor_id, survivor_visitor_id)
    return [] unless Clickhouse.enabled?

    pid = Integer(project_id)
    visitor_ids = acquisition_repair_visitor_ids(pid, merged_visitor_id, survivor_visitor_id)
    return [] if visitor_ids.empty?

    # Only discovered historical months: live months are the watermark lane's job (rebuilt
    # project-wide every pass), so a fresh visitor's merge costs no CH work here at all.
    partitions = visitor_partitions(pid, visitor_ids)
    partitions.each do |partition|
      rebuild_acquisition(partition, project_id: pid, raw_visitor_ids: visitor_ids)
    end
    partitions
  end

  # Months the ids' current effective identities have data in, from the visitor-keyed
  # rollup (ms lookup) instead of a full events scan (~5s at 1.8B rows).
  def self.visitor_partitions(project_id, visitor_ids)
    ids = visitor_ids.map { |id| Integer(id) }.uniq
    return [] if ids.empty?

    rows = Clickhouse.with_request_timeout(DISCOVERY_TIMEOUT_SECONDS) do
      Clickhouse.with do |conn|
        conn.select_all(
          "SELECT DISTINCT toYYYYMM(event_date) AS p FROM visitor_metrics_daily " \
          "WHERE project_id = #{Integer(project_id)} AND visitor_id IN (#{ids.join(',')}) " \
          "SETTINGS max_execution_time = #{DISCOVERY_TIMEOUT_SECONDS}"
        )
      end
    end
    rows.map { |r| r["p"].to_s }
  end
  private_class_method :visitor_partitions

  def self.acquisition_repair_visitor_ids(project_id, merged_visitor_id, survivor_visitor_id)
    final_survivor = ClickhouseIdentityMapService.resolve(project_id, survivor_visitor_id)
    rows = Clickhouse.with do |conn|
      conn.select_all(
        "SELECT from_visitor_id FROM visitor_identity_map FINAL " \
        "WHERE project_id = #{Integer(project_id)} AND to_visitor_id = #{Integer(final_survivor)}"
      )
    end

    ([merged_visitor_id, survivor_visitor_id, final_survivor] + rows.map { |r| r["from_visitor_id"] })
      .compact
      .map { |id| Integer(id) }
      .uniq
  end
  private_class_method :acquisition_repair_visitor_ids

  # Fallback when per-visitor discovery fails: mark the watermark window dirty so
  # recent partitions are still rebuilt for the survivor. Old (out-of-window)
  # partitions are covered by an explicit range rebuild if ever needed.
  def self.mark_watermark_window_dirty
    partitions = watermark_partitions(default_watermark_months, Time.current)
    REDIS.with { |c| c.sadd?(dirty_key, partitions) } if partitions.any?
    partitions
  rescue StandardError
    []
  end

  def self.clear_dirty(partitions)
    return if partitions.empty?

    REDIS.with { |c| c.srem(dirty_key, partitions) }
  end

  # Gates the every-minute current-month-only rebuild (staging freshness); the
  # 10-min full pass is unaffected. Read per call so no boot is needed to flip it.
  def self.fast_lane_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("CLICKHOUSE_ROLLUP_FAST_LANE", false))
  end

  # Default late-event watermark window, in months back from the current month.
  # Configurable via env; defaults to 2 months (a safer window than 1 — late SDK
  # deliveries straddling a month boundary are still re-absorbed even if their
  # mark_dirty was lost). The watermark — not dirty-tracking — is the real
  # guarantee that recent partitions converge.
  def self.default_watermark_months
    Integer(ENV.fetch("CLICKHOUSE_ROLLUP_WATERMARK_MONTHS", 2))
  end

  def self.watermark_partitions(months, now)
    today = now.to_date
    (0..months).map { |i| partition_for(today << i) }
  end

  def self.partition_for(date)
    date.to_date.strftime("%Y%m")
  end

  # --- rebuild ------------------------------------------------------------

  # Recurring 10-min lane: rebuilds ONLY the watermark window (current + previous
  # `watermark_months`). Dirty partitions inside the window are subsumed by it;
  # dirty partitions OUTSIDE it are deliberately deferred to rebuild_stale_dirty —
  # a stream of late events into an old month must not re-trigger a full-partition
  # rebuild every pass. A failed partition keeps its dirty mark; the rest clear.
  def self.rebuild_all_dirty(watermark_months: default_watermark_months)
    return unless Clickhouse.enabled?

    window = watermark_partitions(watermark_months, Time.current)
    dirty_in_window = dirty_partitions & window
    failed = rebuild_partitions(window)
    clear_dirty(dirty_in_window - failed)

    if failed.any?
      # A dead full lane alone never 503s, so it is invisible without this alert.
      Grovs::Metrics.increment("clickhouse.rollup_rebuild.failed", tags: { lane: "full" })
    else
      ClickhouseRollupLiveness.record(:full)
    end
  end

  # Daily catch-up lane: absorbs dirty partitions older than the watermark window
  # (late SDK deliveries, visitor merges into old months). If this lane fails, old
  # months stay silently stale — the catchup metric is its only alarm.
  # NEVER stamp liveness here: that would let a dead full lane serve frozen rollups.
  def self.rebuild_stale_dirty(watermark_months: default_watermark_months, deadline: nil)
    return unless Clickhouse.enabled?

    stale = dirty_partitions - watermark_partitions(watermark_months, Time.current)
    return if stale.empty?

    failed = []
    stale.sort.each_with_index do |partition, i|
      if deadline && Time.current >= deadline
        Rails.logger.warn("ClickhouseRollupRebuildService: catch-up deadline reached, " \
                          "#{stale.size - i} partition(s) deferred to the next run")
        break
      end

      # Claim before rebuilding so a mark added mid-rebuild (e.g. a merge) survives the pass.
      clear_dirty([partition])
      if rebuild_partitions([partition]).any?
        REDIS.with { |c| c.sadd?(dirty_key, partition) }
        failed << partition
      end
    end

    Grovs::Metrics.increment("clickhouse.rollup_rebuild.failed", tags: { lane: "catchup" }) if failed.any?
  end

  # Each (rollup, partition) is isolated: a failure is logged and the rest proceed.
  # Returns the partitions that failed so callers keep only those dirty.
  def self.rebuild_partitions(partitions)
    failed = []

    partitions.each do |partition|
      ok = true
      ROLLUPS.each_key do |rollup_key|
        # A lock skip is not a rebuild: clearing its dirty mark would drop the partition
        # for good, since the holder that skipped us has its own (older) view of dirty.
        ok = false unless rebuild_partition(rollup_key, partition)
      rescue StandardError => e
        ok = false
        Rails.logger.error(
          "ClickhouseRollupRebuildService: rebuild failed for #{rollup_key}/#{partition} — " \
          "#{e.class}: #{e.message}"
        )
      end

      # visitor_acquisition is unpartitioned, so it cannot use REPLACE PARTITION.
      # It stores only argMin/min/max aggregate states, so inserting the states
      # contributed by this partition is enough for normal event-ingestion repair.
      # Merge-specific acquisition repair must stay out of this scheduler path.
      begin
        rebuild_acquisition(partition)
      rescue StandardError => e
        ok = false
        Rails.logger.error(
          "ClickhouseRollupRebuildService: rebuild failed for acquisition/#{partition} — " \
          "#{e.class}: #{e.message}"
        )
      end

      failed << partition unless ok
    end

    failed
  end
  private_class_method :rebuild_partitions

  # Deterministic, dirty-independent rebuild of an inclusive YYYYMM partition range
  # for one or all rollups. This is the history-backfill entry point: it does NOT
  # consult or clear dirty-tracking — you name exactly the partitions to rebuild.
  # from/to are YYYYMM (Integer or String); the range is inclusive and
  # order-insensitive. `rollups:` defaults to all.
  #
  # By default a per-(rollup, partition) failure is logged and the rest proceed
  # (best-effort — matches the maintenance/dirty path). Pass `strict: true` for the
  # ARCHIVE-IMPORT CUTOVER: any failure then RAISES after the pass, so the caller
  # (rake) can abort instead of printing a false "Done." over incomplete rollups.
  # fail_on_skip: lock-skips are benign for the recurring fast lane, fatal for a one-shot repair.
  def self.rebuild_partition_range(from_yyyymm, to_yyyymm, rollups: ROLLUPS.keys + [:acquisition],
                                   strict: false, fail_on_skip: false)
    return unless Clickhouse.enabled?

    partitions = partitions_in_range(from_yyyymm, to_yyyymm)
    failures = []
    skipped = []
    Array(rollups).each do |rollup_key|
      partitions.each do |partition|
        rebuilt = if rollup_key == :acquisition
                    rebuild_acquisition(partition)
                  else
                    rebuild_partition(rollup_key, partition)
                  end
        skipped << [rollup_key, partition] unless rebuilt
      rescue StandardError => e
        failures << { rollup: rollup_key, partition: partition, error: "#{e.class}: #{e.message}" }
        Rails.logger.error(
          "ClickhouseRollupRebuildService: range rebuild failed for #{rollup_key}/#{partition} — " \
          "#{e.class}: #{e.message}"
        )
      end
    end

    skipped, retry_errors = ClickhouseRollupLockRetry.call(skipped, wait_for_lock: fail_on_skip) do |rollup, part|
      rollup == :acquisition ? rebuild_acquisition(part) : rebuild_partition(rollup, part)
    end
    failures.concat(retry_errors)
    skipped.each do |rollup, part|
      Rails.logger.warn("ClickhouseRollupRebuildService: range rebuild SKIPPED #{rollup}/#{part} — lock held")
      failures << { rollup: rollup, partition: part, error: "skipped — lock held" } if fail_on_skip
    end

    # fail_on_skip implies strict, or declaring a skip fatal would raise nothing.
    if (strict || fail_on_skip) && failures.any?
      raise "rebuild_partition_range: #{failures.size} rebuild(s) failed — rollups are INCOMPLETE: #{failures.inspect}"
    end

    partitions
  end

  # Inclusive list of YYYYMM partition strings between two YYYYMM endpoints,
  # walking month-by-month (so it never emits invalid months like 202613).
  def self.partitions_in_range(from_yyyymm, to_yyyymm)
    lo, hi = [yyyymm_to_date(from_yyyymm), yyyymm_to_date(to_yyyymm)].minmax
    out = []
    cur = lo
    while cur <= hi
      out << cur.strftime("%Y%m")
      cur = cur.next_month
    end
    out
  end

  def self.yyyymm_to_date(yyyymm)
    s = yyyymm.to_s
    Date.new(s[0, 4].to_i, s[4, 2].to_i, 1)
  end
  private_class_method :yyyymm_to_date

  # Recompute one partition for one rollup into a staging table, then atomically
  # swap it into the live table. REPLACE PARTITION is atomic and also covers the
  # "partition became empty" case (staging is empty → live partition cleared).
  def self.rebuild_partition(rollup_key, partition)
    config = ROLLUPS.fetch(rollup_key)
    part = Integer(partition)

    # Distributed lock: two workers rebuilding the SAME (rollup, partition) would
    # race on REPLACE PARTITION and could clobber each other (or leak staging
    # tables). SET NX with an owner token; the holder rebuilds, everyone else SKIPS
    # (the other worker's rebuild already reflects the latest canonical). CAS-unlock
    # so a TTL-expired holder can't delete a successor's lock.
    lock_key = lock_key_for(rollup_key, partition)
    token = SecureRandom.hex(16)
    acquired = REDIS.with { |c| c.set(lock_key, token, nx: true, ex: LOCK_TTL) }
    unless acquired
      Rails.logger.info(
        "ClickhouseRollupRebuildService: skipped #{rollup_key}/#{partition} — lock held by another rebuild"
      )
      return false
    end

    begin
      do_rebuild_partition(config, part)
      true
    ensure
      release_lock(lock_key, token)
    end
  end

  # The actual recompute+swap. Staging is dropped in an ensure so a mid-rebuild
  # failure (INSERT or REPLACE) never leaves a stale staging table behind to break
  # the next run.
  def self.do_rebuild_partition(config, part)
    table = config[:table]
    staging = "#{table}_staging_#{part}_#{SecureRandom.hex(4)}"

    # HTTP budget sits above the server-side kill so failure is a CH error, not an abandoned socket.
    Clickhouse.with_request_timeout(REBUILD_MAX_EXECUTION_SECONDS + 10) do
      Clickhouse.with do |conn|
        conn.execute("CREATE TABLE IF NOT EXISTS `#{staging}` AS `#{table}`")
        begin
          conn.execute(insert_query(staging, config[:select], part))
          conn.execute("ALTER TABLE `#{table}` REPLACE PARTITION #{part} FROM `#{staging}`")
        ensure
          conn.execute("DROP TABLE IF EXISTS `#{staging}`")
        end
      end
    end
  end
  private_class_method :do_rebuild_partition

  def self.release_lock(lock_key, token)
    REDIS.with { |c| c.eval(RELEASE_LUA, keys: [lock_key], argv: [token]) }
  rescue StandardError => e
    Rails.logger.warn("ClickhouseRollupRebuildService: lock release failed for #{lock_key}: #{e.message}")
  end
  private_class_method :release_lock

  def self.insert_query(staging, select_sql, partition)
    ClickHouse::Client::Query.new(
      raw_query: "INSERT INTO `#{staging}` #{resolve_select(select_sql)} " \
                 "SETTINGS max_execution_time = #{REBUILD_MAX_EXECUTION_SECONDS}, " \
                 "max_threads = #{REBUILD_MAX_THREADS}",
      placeholders: { partition: partition }
    )
  end
  private_class_method :insert_query

  # Substitute the shared SQL macros. SOURCE_EXPR/HAS_LINK/INSTALL_TYPES are
  # derived from the FROZEN fields via SourceTaxonomy so attribution reconciles
  # with the existing source dashboards.
  def self.resolve_select(select_sql)
    # HAS_LINK expands to a predicate that itself contains source_expr, so substitute
    # it BEFORE the bare SOURCE_EXPR replacement (otherwise its inner SOURCE_EXPR token
    # would be left unresolved).
    select_sql
      .gsub("FROM_WITH_IDENTITY_MAP", FROM_WITH_IDENTITY_MAP)
      .gsub("EFFECTIVE_VISITOR", effective_visitor_id_expr)
      .gsub("HAS_LINK", has_link_predicate)
      .gsub("SOURCE_EXPR", source_expr)
      .gsub("COUNTABLE_TYPES", COUNTABLE_TYPES_SQL)
      .gsub("INSTALL_TYPES", INSTALL_TYPES_SQL)
  end
  private_class_method :resolve_select

  # --- visitor_acquisition (unpartitioned, aggregate-state insert) ---------
  #
  # visitor_acquisition holds ONE row per visitor summarising their entire history
  # (earliest install source, earliest first-touch source). It is NOT partitioned by
  # date, so it can't use the REPLACE PARTITION recompute the daily rollups use.
  #
  # Normal ingestion repair is partition-local: insert the acquisition aggregate states
  # contributed by this dirty YYYYMM partition. AggregatingMergeTree later merges those
  # states with prior rows for the same (project_id, visitor_id). Re-inserting the same
  # partition is safe for these fields because argMin/min/max states are idempotent for
  # duplicate inputs.
  #
  # Visitor merges are different: they can require repairing old states from one visitor
  # id into another. Do not solve that by scanning whole history for every dirty month in
  # the scheduler path; add an explicit merge-repair path if parity proves it necessary.
  ACQUISITION_TABLE = "visitor_acquisition"

  # Hard ceiling for the partition-local acquisition insert. On breach the INSERT fails,
  # the partition stays dirty, and the next cycle retries, but the query is bounded to
  # one YYYYMM partition instead of scanning all history for touched visitors.
  ACQUISITION_MAX_EXECUTION_SECONDS =
    Integer(ENV.fetch("CLICKHOUSE_ACQUISITION_MAX_EXECUTION_SECONDS", 120))

  ACQUISITION_SELECT = <<~SQL
    SELECT
      events.project_id AS project_id,
      EFFECTIVE_VISITOR AS visitor_id,
      argMinIfState(SOURCE_EXPR, (created_at, event_id), event_type IN INSTALL_TYPES) AS install_source,
      argMinIfState(SOURCE_EXPR, (created_at, event_id), HAS_LINK) AS first_touch_source,
      maxIfState(toUInt8(1), event_type IN INSTALL_TYPES) AS has_install,
      maxIfState(toUInt8(1), HAS_LINK) AS has_link,
      minIfState(created_at, event_type IN INSTALL_TYPES) AS install_ts,
      minIfState(created_at, HAS_LINK) AS first_ts
    FROM_WITH_IDENTITY_MAP
    WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}
      AND EFFECTIVE_VISITOR > 0
    GROUP BY project_id, visitor_id
    SETTINGS max_execution_time = #{ACQUISITION_MAX_EXECUTION_SECONDS}, max_threads = #{REBUILD_MAX_THREADS}
  SQL

  # Insert visitor_acquisition states contributed by `partition`. Re-insert is
  # idempotent for the aggregate states stored in this table.
  def self.rebuild_acquisition(partition, project_id: nil, raw_visitor_ids: nil)
    return false unless Clickhouse.enabled?

    part = Integer(partition)
    # Visitor-scoped repairs insert idempotent states — safe concurrently, no lock to contend on.
    if raw_visitor_ids.present?
      Clickhouse.with do |conn|
        conn.execute(acquisition_insert_query(part, project_id: project_id, raw_visitor_ids: raw_visitor_ids))
      end
      return true
    end

    lock_key = lock_key_for(:acquisition, partition)
    token = SecureRandom.hex(16)
    acquired = REDIS.with { |c| c.set(lock_key, token, nx: true, ex: LOCK_TTL) }
    unless acquired
      Rails.logger.info("ClickhouseRollupRebuildService: skipped acquisition/#{partition} — lock held")
      return false
    end

    begin
      Clickhouse.with do |conn|
        conn.execute(acquisition_insert_query(part, project_id: project_id, raw_visitor_ids: nil))
      end
      true
    ensure
      release_lock(lock_key, token)
    end
  end

  # INSERT...SELECT that contributes this partition's acquisition states
  # (effective id, identity-map applied).
  def self.acquisition_insert_query(partition, project_id: nil, raw_visitor_ids: nil)
    select = ACQUISITION_SELECT
    placeholders = { partition: partition }

    if project_id
      select = select.sub(
        "WHERE toYYYYMM(toDate(created_at)) = {partition:UInt32}",
        "WHERE events.project_id = {project_id:UInt64}\n      AND toYYYYMM(toDate(created_at)) = {partition:UInt32}"
      )
      placeholders[:project_id] = Integer(project_id)
    end

    if raw_visitor_ids.present?
      ids = raw_visitor_ids.map { |id| Integer(id) }.uniq
      select = select.sub(
        "AND EFFECTIVE_VISITOR > 0",
        "AND events.visitor_id IN (#{ids.join(',')})\n      AND EFFECTIVE_VISITOR > 0"
      )
    end

    ClickHouse::Client::Query.new(
      raw_query: "INSERT INTO `#{ACQUISITION_TABLE}` #{resolve_select(select)}",
      placeholders: placeholders
    )
  end
  private_class_method :acquisition_insert_query
end
# rubocop:enable Metrics/ModuleLength
