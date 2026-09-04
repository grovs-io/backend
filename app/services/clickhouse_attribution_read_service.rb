# frozen_string_literal: true

# Phase 5 — per-visitor attribution reads (DUAL-RUN ONLY; not wired to dashboards).
#
# Resolves each active visitor in a date range to ONE source under a selectable model
# (install / first / last) and returns the exact distinct-visitor count per source. This
# is the eventual replacement for ClickhouseReadService.project_source_daily_stats, which
# counts per-EVENT-day source (a visitor can appear under several sources). It is gated by
# Clickhouse.read_enabled? and parity-checked before any cutover.
#
# Models (each self-consistent):
#   :install — earliest install's source; no install → earliest link-touch; no link → organic
#   :first   — earliest link-touch source; no link → organic
#   :last    — last link-touch source AS-OF the range end; no link up to then → organic
#
# AS-OF CONTRACT (precise — do not overclaim "past days never change"):
#   install & first are immutable to FUTURE events: they argMin over the EARLIEST touch in
#   the visitor's whole history, so an event DATED AFTER an earlier one can never displace it.
#   A late event DATED BEFORE the current earliest WOULD legitimately change them — that is
#   correct as-of behaviour, not a bug (we attribute to the true earliest touch on record).
#   :last is computed as-of the range END from the daily snapshot (visitor_last_touch_daily):
#   an answer for a date range reflects ALL events DATED within/up-to that range. Therefore
#   an event DATED INSIDE a past range DOES change that range's last-touch answer (correct
#   as-of), while an event DATED AFTER the range NEVER changes it (it only adds NEW snapshot
#   days beyond the range end). No immutable snapshot table is needed — the contract is
#   "answers are a function of the events DATED in the queried window", which is the
#   intended as-of semantics.
#
# Active-visitor set comes from visitor_metrics_daily (visitor_id != 0) for the range; an
# ANY INNER JOIN onto the per-visitor attribution restricts attribution to in-range actives.
# uniqExact is unbounded, so every query carries explicit memory guards.
module ClickhouseAttributionReadService
  extend Analytics::QueryHelpers

  MODELS = %i[install first last].freeze

  # Last-touch attribution window (days). A link-touch older than this before the range
  # end is aged out → the visitor resolves to organic under :last (re-engagement expired).
  # Industry-aligned (AppsFlyer re-engagement default). Applied as a partition-pruning
  # WHERE lower bound — event_date >= end_date - N folds to a constant date, so ClickHouse
  # skips partitions older than the window instead of scanning all history. Env-overridable.
  LAST_TOUCH_WINDOW_DAYS = Integer(ENV.fetch("CLICKHOUSE_LAST_TOUCH_WINDOW_DAYS", 30))

  # uniqExact memory guards. Cap RAM and spill GROUP BY to disk past a threshold so a
  # high-cardinality project can't OOM the server. Env-overridable.
  MAX_MEMORY_BYTES = Integer(ENV.fetch("CLICKHOUSE_ATTRIBUTION_MAX_MEMORY_BYTES", 4_000_000_000))
  MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY =
    Integer(ENV.fetch("CLICKHOUSE_ATTRIBUTION_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY", 2_000_000_000))
  MEMORY_GUARDS =
    "SETTINGS max_memory_usage = #{MAX_MEMORY_BYTES}, " \
    "max_bytes_before_external_group_by = #{MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY}"

  # Oracle-only budget; spill threshold must stay ~1/4 of the cap or it OOMs before spilling.
  ORACLE_MAX_MEMORY_BYTES =
    Integer(ENV.fetch("CLICKHOUSE_ORACLE_MAX_MEMORY_BYTES", 32_000_000_000))
  ORACLE_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY =
    Integer(ENV.fetch("CLICKHOUSE_ORACLE_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY", 8_000_000_000))
  ORACLE_MEMORY_GUARDS =
    "SETTINGS max_memory_usage = #{ORACLE_MAX_MEMORY_BYTES}, " \
    "max_bytes_before_external_group_by = #{ORACLE_MAX_BYTES_BEFORE_EXTERNAL_GROUP_BY}"

  # Distinct-visitor count per resolved source over the range. Returns
  # [{ "source" => "campaigns", "visitors" => 3 }, ...]. [] when reads disabled.
  # raise_on_error: the gate must tell a failed query from a genuinely empty result.
  def self.source_breakdown(project_id, start_date:, end_date:, model: :install, raise_on_error: false)
    return [] unless Clickhouse.read_enabled?
    raise ArgumentError, "Unknown attribution model: #{model}" unless MODELS.include?(model.to_sym)

    query = breakdown_query(Integer(project_id), start_date, end_date, model.to_sym)
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:source_breakdown, e)
    raise if raise_on_error

    []
  end

  # The single-visitor resolved source — used by tests and by per-visitor lookups.
  # Whole-history (NOT range-bounded) for install/first; last uses all snapshot days.
  # as_of sets the :last point-in-time (defaults to today). Pass the PURCHASE/event date when
  # attributing a backdated purchase, so its last-touch window is anchored to the purchase, not now.
  def self.resolved_source_for(project_id, visitor_id, model: :install, as_of: Date.current)
    return nil unless Clickhouse.read_enabled?

    query = single_visitor_query(Integer(project_id), Integer(visitor_id), model.to_sym, as_of: as_of)
    row = Clickhouse.with { |conn| conn.select_all(query).first }
    row && row["source"]
  rescue StandardError => e
    log_query_failure(:resolved_source_for, e)
    nil
  end

  # Exact distinct visitors per value of a TIME-VARYING dimension (version/country/
  # platform) over the range. Counted per-day then merged — a visitor active under two
  # values in the range appears under both (their own time-varying definition).
  def self.dimension_breakdown(project_id, start_date:, end_date:, dimension:)
    return [] unless Clickhouse.read_enabled?

    query = ClickHouse::Client::Query.new(
      raw_query: <<~SQL,
        SELECT value, uniqExactMerge(visitors_state) AS visitors
        FROM visitor_dimension_daily
        WHERE project_id = {project_id:UInt64}
          AND dimension = {dimension:String}
          AND event_date >= {start_date:Date} AND event_date <= {end_date:Date}
        GROUP BY value
        ORDER BY visitors DESC, value ASC
        #{MEMORY_GUARDS}
      SQL
      placeholders: {
        project_id: Integer(project_id),
        dimension: dimension.to_s,
        start_date: format_date(start_date),
        end_date: format_date(end_date)
      }
    )
    Clickhouse.with { |conn| conn.select_all(query) }
  rescue StandardError => e
    log_query_failure(:dimension_breakdown, e)
    []
  end

  # --- query builders ------------------------------------------------------

  # Resolved-source expression over the merged acquisition aggregate row.
  RESOLVED = {
    install: "if(has_install > 0, install_source, if(has_link > 0, first_touch_source, 'organic'))",
    first: "if(has_link > 0, first_touch_source, 'organic')"
    # :last is resolved from the last-touch snapshot, handled separately.
  }.freeze

  def self.breakdown_query(pid, start_date, end_date, model)
    placeholders = {
      project_id: pid,
      start_date: format_date(start_date),
      end_date: format_date(end_date)
    }
    raw = model == :last ? last_breakdown_sql : acquisition_breakdown_sql(RESOLVED.fetch(model))
    ClickHouse::Client::Query.new(raw_query: raw, placeholders: placeholders)
  end
  private_class_method :breakdown_query

  # Active visitors in range LEFT JOIN their whole-history acquisition row. LEFT (not INNER):
  # if the acquisition rebuild lags or fails for an active visitor, they must still count as
  # organic (av.has_* default to 0 on a missing match), not vanish from the total — mirrors the
  # :last breakdown. Count active.visitor_id (always present) so unmatched rows still count.
  def self.acquisition_breakdown_sql(resolved_expr)
    <<~SQL
      SELECT #{resolved_expr} AS source, uniqExact(active.visitor_id) AS visitors
      FROM (#{active_visitors_sql}) AS active
      LEFT JOIN (#{acquisition_merge_sql}) AS av
        ON active.visitor_id = av.visitor_id
      GROUP BY source
      ORDER BY visitors DESC, source ASC
      #{MEMORY_GUARDS}
    SQL
  end
  private_class_method :acquisition_breakdown_sql

  # Last-touch AS-OF range end: snapshot rows with event_date <= end_date, argMaxMerge to the
  # last link-touch up to then. Active visitors with no link-touch up to the end → organic.
  def self.last_breakdown_sql
    <<~SQL
      SELECT
        if(lt.has_last > 0, lt.last_touch_source, 'organic') AS source,
        uniqExact(active.visitor_id) AS visitors
      FROM (#{active_visitors_sql}) AS active
      LEFT JOIN (#{last_touch_merge_sql}) AS lt
        ON active.visitor_id = lt.visitor_id
      GROUP BY source
      ORDER BY visitors DESC, source ASC
      #{MEMORY_GUARDS}
    SQL
  end
  private_class_method :last_breakdown_sql

  # Distinct active visitors in the range (visitor_id != 0).
  def self.active_visitors_sql
    <<~SQL.strip
      SELECT DISTINCT visitor_id
      FROM visitor_metrics_daily
      WHERE project_id = {project_id:UInt64}
        AND event_date >= {start_date:Date} AND event_date <= {end_date:Date}
        AND visitor_id != 0
    SQL
  end
  private_class_method :active_visitors_sql

  # Whole-history acquisition per visitor, finalized via *Merge (NOT bare FINAL).
  def self.acquisition_merge_sql(visitor_filter: "")
    <<~SQL.strip
      SELECT
        visitor_id,
        argMinIfMerge(install_source) AS install_source,
        argMinIfMerge(first_touch_source) AS first_touch_source,
        maxIfMerge(has_install) AS has_install,
        maxIfMerge(has_link) AS has_link
      FROM visitor_acquisition
      WHERE project_id = {project_id:UInt64} #{visitor_filter}
      GROUP BY project_id, visitor_id
    SQL
  end
  private_class_method :acquisition_merge_sql

  # Last-touch as-of the range end per visitor, finalized via *Merge. has_last is the
  # real link-touch flag: a visitor with events but no link-touch IN THE WINDOW → 0.
  # The lower bound (event_date >= end_date - LAST_TOUCH_WINDOW_DAYS) both enforces the
  # attribution window AND prunes partitions older than it. The window-days constant is a
  # trusted server value (not user input), so it is interpolated as an integer literal.
  def self.last_touch_merge_sql(visitor_filter: "")
    <<~SQL.strip
      SELECT
        visitor_id,
        argMaxIfMerge(last_touch_source) AS last_touch_source,
        maxIfMerge(has_link) AS has_last
      FROM visitor_last_touch_daily
      WHERE project_id = {project_id:UInt64}
        AND event_date <= {end_date:Date}
        AND event_date >= {end_date:Date} - #{LAST_TOUCH_WINDOW_DAYS} #{visitor_filter}
      GROUP BY project_id, visitor_id
    SQL
  end
  private_class_method :last_touch_merge_sql

  def self.single_visitor_query(pid, vid, model, as_of: Date.current)
    placeholders = { project_id: pid, visitor_id: vid }
    raw =
      if model == :last
        # Point lookup: the visitor's last touch as-of `as_of` (today by default) within the window.
        # last_touch_merge_sql needs end_date bound (it always did) — bind it here so the window resolves.
        placeholders[:end_date] = format_date(as_of)
        <<~SQL
          SELECT if(has_last > 0, last_touch_source, 'organic') AS source
          FROM (#{last_touch_merge_sql(visitor_filter: 'AND visitor_id = {visitor_id:UInt64}')}) AS lt
        SQL
      else
        <<~SQL
          SELECT #{RESOLVED.fetch(model)} AS source
          FROM (#{acquisition_merge_sql(visitor_filter: 'AND visitor_id = {visitor_id:UInt64}')}) AS av
        SQL
      end
    ClickHouse::Client::Query.new(raw_query: raw, placeholders: placeholders)
  end
  private_class_method :single_visitor_query

  # --- trusted recompute (parity oracle) -----------------------------------
  #
  # Resolved-source breakdown computed STRAIGHT from the deduped events
  # (identity-map applied, FINAL dedup) — no acquisition/snapshot intermediary. Used
  # by Billing::ClickhouseParityCheck as the trusted oracle the rollups must match.
  # Mirrors the served reads' resolver exactly so a zero delta proves faithfulness.
  def self.trusted_recompute_sql(model)
    raise ArgumentError, "Unknown attribution model: #{model}" unless MODELS.include?(model.to_sym)

    rb = ClickhouseRollupRebuildService
    eff = rb.effective_visitor_id_expr
    src = rb.source_expr
    has_link = rb.has_link_predicate
    from = rb.const_get(:FROM_WITH_IDENTITY_MAP)
    install_types = rb.const_get(:INSTALL_TYPES_SQL)

    active = <<~SQL.strip
      SELECT DISTINCT #{eff} AS visitor_id
      #{from}
      WHERE events.project_id = {project_id:UInt64}
        AND toDate(created_at) >= {start_date:Date} AND toDate(created_at) <= {end_date:Date}
        AND #{eff} > 0
    SQL

    case model.to_sym
    when :last
      # Last link-touch AS-OF end_date WITHIN the window, per visitor, straight from
      # canonical. Mirrors last_touch_merge_sql's window so the parity oracle and the
      # served read agree (a touch older than the window ages out to organic in both).
      acq = <<~SQL.strip
        SELECT
          #{eff} AS visitor_id,
          argMaxIf(#{src}, (created_at, event_id), #{has_link}) AS last_touch_source,
          maxIf(toUInt8(1), #{has_link}) AS has_last
        #{from}
        WHERE events.project_id = {project_id:UInt64}
          AND toDate(created_at) <= {end_date:Date}
          AND toDate(created_at) >= {end_date:Date} - #{LAST_TOUCH_WINDOW_DAYS}
          AND #{eff} > 0
        GROUP BY #{eff}
      SQL
      resolved = "if(acq.has_last > 0, acq.last_touch_source, 'organic')"
    else
      acq = <<~SQL.strip
        SELECT
          #{eff} AS visitor_id,
          argMinIf(#{src}, (created_at, event_id), event_type IN #{install_types}) AS install_source,
          argMinIf(#{src}, (created_at, event_id), #{has_link}) AS first_touch_source,
          maxIf(toUInt8(1), event_type IN #{install_types}) AS has_install,
          maxIf(toUInt8(1), #{has_link}) AS has_link
        #{from}
        WHERE events.project_id = {project_id:UInt64}
          AND #{eff} > 0
        GROUP BY #{eff}
      SQL
      resolved =
        if model.to_sym == :install
          "if(acq.has_install > 0, acq.install_source, if(acq.has_link > 0, acq.first_touch_source, 'organic'))"
        else
          "if(acq.has_link > 0, acq.first_touch_source, 'organic')"
        end
    end

    # LEFT JOIN (not INNER): for :last the acq subquery is windowed, so an active visitor
    # whose only in-range activity predates the window has NO acq row — they must still count
    # as organic (acq.has_* defaults to 0 on a missing match), exactly as the served read's
    # LEFT JOIN does. INNER would silently DROP them and undercount wide ranges. For
    # install/first acq is whole-history, so every active visitor matches and LEFT == INNER.
    <<~SQL
      SELECT #{resolved} AS source, uniqExact(active.visitor_id) AS visitors
      FROM (#{active}) AS active
      LEFT JOIN (#{acq}) AS acq ON active.visitor_id = acq.visitor_id
      GROUP BY source
      ORDER BY source ASC
      #{ORACLE_MEMORY_GUARDS}
    SQL
  end

  def self.format_date(value)
    case value
    when Date, Time, ActiveSupport::TimeWithZone then value.to_date.strftime("%Y-%m-%d")
    else Date.parse(value.to_s).strftime("%Y-%m-%d")
    end
  end
  private_class_method :format_date
end
