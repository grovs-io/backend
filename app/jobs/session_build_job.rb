# frozen_string_literal: true

# Sessionizes CH events into session_events + session_summary, bucketing visitors by their
# identity-map survivor so a browser click and the install it caused share one session.
# Design + accepted limits: docs/plans/2026-08-06-session-stitching.md
class SessionBuildJob < ApplicationJob
  include Analytics::QueryHelpers
  include SingleFlightJob

  queue_as :maintenance

  # false processes every visitor now — for one-shot rebuilds over settled history.
  attr_writer :defer_open_sessions

  DEFAULT_LOOKBACK_DAYS = 3
  INACTIVITY_GAP_SECONDS = 1800 # 30 minutes
  PENDING_CLICK_WINDOW_SECONDS = 3600 # how far back a click still counts as waiting
  BATCH_SIZE = 10_000
  BUCKET_BATCH_SIZE = 500
  MAX_SESSION_ID_LENGTH = 256
  EVENT_PAGE_SIZE = 50_000
  LOCK_TTL = 30.minutes # single-flight: overlapping runs would double-insert (session_events has no dedup)

  # Returns :skipped, :disabled, or the failed project ids, so a rebuild can refuse to
  # publish rollups over a range this run did not sessionize.
  def perform(lookback_days: nil, lock_ttl: LOCK_TTL)
    return :disabled unless Clickhouse.enabled? && Clickhouse.read_enabled?

    @lookback_days = lookback_days || DEFAULT_LOOKBACK_DAYS
    failed = []
    ran = false

    single_flight!(key: "session_build", ttl: lock_ttl) do |deadline|
      ran = true
      projects_with_recent_events.each do |project_id|
        # Past the lock TTL another run can start; session_events has no dedup, so
        # overlapping inserts would duplicate. Stop and report instead.
        if Time.current >= deadline
          failed << :deadline_exceeded
          break
        end

        build_sessions_for_project(project_id)
      rescue StandardError => e
        failed << project_id
        Rails.logger.error("SessionBuildJob: failed for project #{project_id}: #{e.class} - #{e.message}")
      end
    end
    Rails.logger.warn("SessionBuildJob: incomplete pass #{failed.inspect}") if failed.any?
    ran ? failed : :skipped
  end

  private

  def lookback_days
    @lookback_days || DEFAULT_LOOKBACK_DAYS
  end

  def projects_with_recent_events
    sql = <<~SQL
      SELECT DISTINCT project_id
      FROM events
      WHERE created_at >= now() - INTERVAL #{lookback_days} DAY
    SQL
    Clickhouse.with { |conn| conn.select_all(sql) }.map { |r| r['project_id'] }
  end

  def build_sessions_for_project(project_id)
    pid = Integer(project_id)
    buckets = eligible_visitor_buckets(pid)
    return if buckets.empty?

    affected_sessions = sessionize_and_insert(pid, buckets)
    return unless affected_sessions.any?

    alias_pairs = build_alias_pairs(buckets)
    build_session_summaries(pid, affected_sessions, alias_pairs)
    purge_superseded_summaries(pid, alias_pairs.keys, affected_sessions)
  end

  # Returns the Set of session_ids that received new events.
  def sessionize_and_insert(pid, buckets)
    affected = Set.new
    buckets.each_slice(BUCKET_BATCH_SIZE) do |batch|
      batch_sessions = sessionize_visitor_batch(pid, batch)
      affected.merge(batch_sessions) if batch_sessions
    end
    affected
  end

  # Summaries are written under the survivor, so a pre-merge row under the old visitor is a
  # different sort key that RMT will never replace — link_session_daily would count it twice.
  # Deletes ONLY sessions this run rewrote: a merged visitor's older history was never
  # rebuilt under the survivor, so removing it would destroy it outright.
  def purge_superseded_summaries(pid, merged_ids, rebuilt_sessions)
    return if merged_ids.empty? || rebuilt_sessions.blank?

    list = merged_ids.join(', ')
    targets = superseded_session_ids(pid, list) & rebuilt_sessions.to_a
    return if targets.empty?

    ids = targets.map { |sid| "'#{sanitize_string(sid)}'" }.join(', ')
    Clickhouse.with do |conn|
      conn.execute("ALTER TABLE session_summary DELETE WHERE project_id = #{pid} " \
                   "AND visitor_id IN (#{list}) AND session_id IN (#{ids}) " \
                   "AND event_date >= today() - #{lookback_days}")
    end
  end

  # Bounded by one visitor's own recent sessions, and keeps the mutation off older partitions.
  def superseded_session_ids(pid, list)
    rows = Clickhouse.with do |conn|
      conn.select_all("SELECT DISTINCT session_id FROM session_summary WHERE project_id = #{pid} " \
                      "AND visitor_id IN (#{list}) AND event_date >= today() - #{lookback_days}")
    end
    rows.map { |r| r['session_id'] }
  end

  # Returns [[survivor, [raw visitor ids]], ...], minus the buckets still waiting (see defer_bucket?).
  def eligible_visitor_buckets(pid)
    rows = Clickhouse.with { |conn| conn.select_all(visitor_bucket_sql(pid)) }.to_a
    return [] if rows.empty?

    pending = visitors_with_unsessionized_events(pid)
    return [] if pending.empty?

    rows.group_by { |r| r['survivor'].to_i }
        .filter_map do |survivor, bucket|
          next if defer_bucket?(bucket)

          vids = bucket.map { |r| r['visitor_id'].to_i }
          # A settled bucket pages an empty result at full scan cost; decide that here, once per project.
          next unless vids.any? { |vid| pending.include?(vid) }

          [survivor, vids]
        end
  end

  # Raw (pre-merge) visitor ids with at least one event the anti-join in fetch_events_page would return.
  def visitors_with_unsessionized_events(pid)
    sql = <<~SQL
      SELECT DISTINCT e.visitor_id AS visitor_id
      FROM events AS e
      LEFT ANTI JOIN (
        SELECT project_id, event_id
        FROM session_events
        WHERE project_id = #{pid}
          AND #{session_events_date_floor("INTERVAL #{lookback_days} DAY")}
          AND created_at >= now() - INTERVAL #{lookback_days} DAY
          AND event_id != ''
      ) se ON se.project_id = e.project_id AND se.event_id = e.event_id
      WHERE e.project_id = #{pid}
        AND e.created_at >= now() - INTERVAL #{lookback_days} DAY
    SQL
    Clickhouse.with { |conn| conn.select_all(sql) }.to_a.map { |r| r['visitor_id'].to_i }.to_set
  end

  # Both aggregates count only blank-session events NOT yet in session_events: an
  # already-sessionized old click must not strip protection from a fresh one.
  def visitor_bucket_sql(pid)
    scan_seconds = PENDING_CLICK_WINDOW_SECONDS * 2
    open_click = "e.session_id = '' AND se.event_id = '' " \
                 "AND e.created_at >= now() - INTERVAL #{scan_seconds} SECOND"

    <<~SQL
      SELECT v.visitor_id AS visitor_id,
             if(m.to_visitor_id > 0, m.to_visitor_id, v.visitor_id) AS survivor,
             if(v.newest_open >= now() - INTERVAL #{INACTIVITY_GAP_SECONDS} SECOND
                AND v.oldest_open >= now() - INTERVAL #{PENDING_CLICK_WINDOW_SECONDS} SECOND, 1, 0) AS waiting
      FROM (
        SELECT e.visitor_id AS visitor_id,
               maxIf(e.created_at, #{open_click}) AS newest_open,
               minIf(e.created_at, #{open_click}) AS oldest_open
        FROM events e
        LEFT JOIN (
          SELECT project_id, event_id
          FROM session_events
          WHERE project_id = #{pid}
            AND #{session_events_date_floor("INTERVAL #{scan_seconds} SECOND")}
            AND created_at >= now() - INTERVAL #{scan_seconds} SECOND
            AND event_id != ''
        ) se ON se.project_id = e.project_id AND se.event_id = e.event_id
        WHERE e.project_id = #{pid}
          AND e.created_at >= now() - INTERVAL #{lookback_days} DAY
        GROUP BY e.visitor_id
      ) v
      LEFT JOIN (
        SELECT from_visitor_id, to_visitor_id
        FROM #{ClickhouseIdentityMapService::TABLE} FINAL
        WHERE project_id = #{pid}
      ) m ON m.from_visitor_id = v.visitor_id
    SQL
  end

  # Newest bounds protection (a click can still adopt); oldest bounds the wait, so a visitor
  # emitting blank-session events forever is not deferred until they age out of the lookback.
  def defer_bucket?(bucket)
    return false unless defer_open_sessions?

    bucket.any? { |r| r['waiting'].to_i.positive? }
  end

  def defer_open_sessions?
    @defer_open_sessions = true if @defer_open_sessions.nil?
    @defer_open_sessions
  end

  # Pages on (effective visitor, created_at); sessionization state carries across pages.
  def sessionize_visitor_batch(pid, buckets)
    raw_vids = buckets.flat_map { |_survivor, vids| Array(vids).map { |vid| Integer(vid) } }
    # The survivor may have no events of its own in the window, yet still own stored rows.
    scope_list = (raw_vids + buckets.map { |survivor, _| Integer(survivor) }).uniq.join(', ')
    vid_list = raw_vids.join(', ')
    alias_pairs = build_alias_pairs(buckets)
    eff = visitor_expr(alias_pairs, 'e.visitor_id')

    affected_sessions = Set.new
    prior_sessions = fetch_prior_session_state(pid, scope_list, alias_pairs)
    state = {}
    cursor = nil

    loop do
      page = fetch_events_page(pid, vid_list, scope_list, eff, cursor)
      break if page.empty?

      rows, page_sessions, state = sessionize_events(page, pid, state, prior_sessions: prior_sessions)
      affected_sessions.merge(page_sessions)
      insert_session_rows(rows)

      break if page.size < EVENT_PAGE_SIZE

      last = page.last
      cursor = { visitor_id: last['visitor_id'], created_at: ensure_time(last['created_at']) }
    end

    # Events still awaiting adoption cannot be emitted by the call that buffered them.
    tail_rows, tail_sessions = flush_pending_rows(state[:pending])
    affected_sessions.merge(tail_sessions)
    insert_session_rows(tail_rows)

    affected_sessions.presence
  end

  def insert_session_rows(rows)
    rows.each_slice(BATCH_SIZE) do |batch|
      Clickhouse.with { |conn| conn.insert('session_events', batch) }
    end
  end

  def build_alias_pairs(buckets)
    buckets.each_with_object({}) do |(survivor, vids), pairs|
      vids.each { |vid| pairs[vid] = survivor if vid != survivor }
    end
  end

  # Inline, not a join: a join-derived bucket would stop CH pruning the events scan.
  def visitor_expr(alias_pairs, column)
    return column if alias_pairs.empty?

    # toUInt64 keeps the expression the same type as the column in SELECT, GROUP BY and the cursor.
    "toUInt64(transform(#{column}, [#{alias_pairs.keys.join(', ')}], " \
      "[#{alias_pairs.values.join(', ')}], #{column}))"
  end

  # The anti-join keys on event_id alone — a row stored pre-merge holds the old visitor, so
  # keying on visitor too would miss it and re-insert into a table with no dedup.
  def fetch_events_page(pid, vid_list, scope_list, eff, cursor)
    sql = <<~SQL
      SELECT
          e.event_id, e.project_id, #{eff} AS visitor_id, e.device_id, e.event_type, e.event_name,
          e.screen_name, e.platform, e.app_version, e.country, e.city, e.device_model,
          e.os, e.os_version, e.link_id, e.campaign_id,
          e.tracking_source, e.tracking_medium, e.tracking_campaign,
          e.ads_platform, e.sdk_identifier,
          e.engagement_time, e.properties,
          e.session_id, e.sdk_generated, e.link_visitor_id, e.created_at
      FROM events AS e FINAL
      LEFT ANTI JOIN (
        SELECT project_id, event_id
        FROM session_events
        WHERE project_id = #{pid}
          AND #{session_events_date_floor("INTERVAL #{lookback_days} DAY")}
          AND visitor_id IN (#{scope_list})
          AND created_at >= now() - INTERVAL #{lookback_days} DAY
          AND event_id != ''
      ) se ON se.project_id = e.project_id
          AND se.event_id = e.event_id
      WHERE e.project_id = #{pid}
        AND e.visitor_id IN (#{vid_list})
        AND e.created_at >= now() - INTERVAL #{lookback_days} DAY
        #{build_cursor_clause(cursor, eff)}
      ORDER BY #{eff}, e.created_at
      LIMIT #{EVENT_PAGE_SIZE}
    SQL
    Clickhouse.with { |conn| conn.select_all(sql) }.to_a
  end

  # Seeds gap detection and the synthetic counter so incremental runs don't reset to 0.
  def fetch_prior_session_state(pid, scope_list, alias_pairs)
    eff = visitor_expr(alias_pairs, 'visitor_id')
    sql = <<~SQL
      SELECT
        #{eff} AS vid,
        max(created_at) AS last_ts,
        argMaxIf(session_id, created_at, session_id LIKE 'synth\\_%') AS last_synth_session
      FROM session_events
      WHERE project_id = #{pid}
        AND #{session_events_date_floor("INTERVAL #{lookback_days} DAY")}
        AND visitor_id IN (#{scope_list})
        AND created_at >= now() - INTERVAL #{lookback_days} DAY
      GROUP BY #{eff}
    SQL
    rows = Clickhouse.with { |conn| conn.select_all(sql) }.to_a

    result = {}
    rows.each do |r|
      last_synth = r['last_synth_session'].to_s
      counter = last_synth.present? ? (last_synth.split('_').last.to_i rescue 0) : 0
      result[r['vid']] = { session_counter: counter, last_ts: ensure_time(r['last_ts']) }
    end
    result
  end

  # session_events sorts on (project_id, event_date, ...): created_at alone reads the project's whole history.
  def session_events_date_floor(interval)
    "event_date >= toDate(now() - #{interval}) - 1"
  end

  def build_cursor_clause(cursor, eff)
    return '' unless cursor

    vid = Integer(cursor[:visitor_id])
    ts = format_timestamp(cursor[:created_at])
    "AND (#{eff} > #{vid} OR (#{eff} = #{vid} AND e.created_at > '#{ts}'))"
  end

  # Attribution columns take argMin (the click that opened the session), device columns
  # argMax (the app, not the browser the session may have started in).
  def build_session_summaries(project_id, session_ids, alias_pairs = {})
    pid = Integer(project_id)
    buy_event = Grovs::Purchases::EVENT_BUY # the stored VALUE "buy", not the literal 'PURCHASE_EVENT_BUY'

    session_ids.each_slice(1000) do |batch|
      list = batch.map { |sid| "'#{sanitize_string(sid)}'" }.join(', ')
      Clickhouse.with { |conn| conn.execute(session_summary_insert_sql(pid, buy_event, list, alias_pairs)) }
    end
  end

  # Conversion/revenue via LEFT JOIN + regroup, NOT correlated subqueries —
  # those fail to plan on CH 25.x ("Cannot clone ReadFromPreparedSource").
  # Both sides resolve through the identity map: rows written before a merge would otherwise
  # aggregate as a second session, and purchases under the merged visitor would stop joining.
  # Purchases match on session_id when they carry one. Resolving the visitor through the map
  # collapses two join keys into one, so a window-only rule pays a purchase into every
  # concurrent session of a merged person — double-counted revenue.
  def session_summary_insert_sql(pid, buy_event, list, alias_pairs = {})
    eff_pe = visitor_expr(alias_pairs, 'visitor_id')
    # The id must be one this batch actually rebuilt, or a purchase tagged with a session we
    # are not aggregating matches nothing and drops out of revenue entirely.
    pe_match = "if(pe.session_id != '' AND pe.session_id IN (#{list}), " \
               "pe.session_id = agg.session_id, " \
               "pe.created_at >= agg.started_at AND pe.created_at <= agg.ended_at)"

    <<~SQL
            INSERT INTO session_summary (
                project_id, session_id, visitor_id, event_date,
                platform, app_version, country, city, device_model,
                os, os_version, tracking_source, tracking_medium,
                tracking_campaign, ads_platform, sdk_identifier,
                link_id, campaign_id, sdk_generated, link_visitor_id,
                screen_count, event_count, duration_ms,
                first_screen, last_screen, has_conversion,
                revenue_usd_cents, started_at, ended_at
            )
            SELECT
                agg.project_id,
                agg.session_id,
                agg.visitor_id,
                agg.event_date,
                agg.platform,
                agg.app_version,
                agg.country,
                agg.city,
                agg.device_model,
                agg.os,
                agg.os_version,
                agg.tracking_source,
                agg.tracking_medium,
                agg.tracking_campaign,
                agg.ads_platform,
                agg.sdk_identifier,
                agg.link_id,
                agg.campaign_id,
                agg.sdk_generated,
                agg.link_visitor_id,
                agg.screen_count,
                agg.event_count,
                agg.duration_ms,
                agg.first_screen,
                agg.last_screen,
                if(countIf(#{pe_match}) > 0, 1, 0) AS has_conversion,
                sumIf(pe.usd_price_cents, #{pe_match}) AS revenue_usd_cents,
                agg.started_at,
                agg.ended_at
            FROM (
      #{session_agg_sql(pid, list, alias_pairs)}      ) agg
            LEFT JOIN (
              SELECT #{eff_pe} AS visitor_id, session_id, created_at, usd_price_cents
              FROM purchase_events FINAL
              WHERE project_id = #{pid}
                AND event_type = '#{buy_event}'
                AND created_at >= now() - INTERVAL #{lookback_days} DAY
            ) pe ON pe.visitor_id = agg.visitor_id
            GROUP BY
                agg.project_id, agg.session_id, agg.visitor_id, agg.event_date,
                agg.platform, agg.app_version, agg.country, agg.city, agg.device_model,
                agg.os, agg.os_version, agg.tracking_source, agg.tracking_medium,
                agg.tracking_campaign, agg.ads_platform, agg.sdk_identifier,
                agg.link_id, agg.campaign_id, agg.sdk_generated, agg.link_visitor_id,
                agg.screen_count, agg.event_count, agg.duration_ms,
                agg.first_screen, agg.last_screen, agg.started_at, agg.ended_at
    SQL
  end

  def session_agg_sql(pid, list, alias_pairs)
    eff = visitor_expr(alias_pairs, 'se.visitor_id')

    <<~SQL
      SELECT
          se.project_id,
          se.session_id,
          #{eff} AS visitor_id,
          min(se.event_date) AS event_date,
          argMax(se.platform, se.created_at) AS platform,
          argMax(se.app_version, se.created_at) AS app_version,
          argMax(se.country, se.created_at) AS country,
          argMax(se.city, se.created_at) AS city,
          argMax(se.device_model, se.created_at) AS device_model,
          argMax(se.os, se.created_at) AS os,
          argMax(se.os_version, se.created_at) AS os_version,
          argMin(se.tracking_source, se.created_at) AS tracking_source,
          argMin(se.tracking_medium, se.created_at) AS tracking_medium,
          argMin(se.tracking_campaign, se.created_at) AS tracking_campaign,
          argMin(se.ads_platform, se.created_at) AS ads_platform,
          argMax(se.sdk_identifier, se.created_at) AS sdk_identifier,
          argMin(se.link_id, se.created_at) AS link_id,
          argMin(se.campaign_id, se.created_at) AS campaign_id,
          argMin(se.sdk_generated, se.created_at) AS sdk_generated,
          argMin(se.link_visitor_id, se.created_at) AS link_visitor_id,
          countIf(se.screen_name != '') AS screen_count,
          count() AS event_count,
          dateDiff('millisecond', min(se.created_at), max(se.created_at)) AS duration_ms,
          argMinIf(se.screen_name, se.created_at, se.screen_name != '') AS first_screen,
          argMaxIf(se.screen_name, se.created_at, se.screen_name != '') AS last_screen,
          min(se.created_at) AS started_at,
          max(se.created_at) AS ended_at
      FROM session_events se
      WHERE se.project_id = #{pid}
        AND se.#{session_events_date_floor("INTERVAL #{lookback_days} DAY")}
        AND se.session_id IN (#{list})
        AND se.created_at >= now() - INTERVAL #{lookback_days} DAY
      GROUP BY se.project_id, se.session_id, #{eff}
    SQL
  end

  # A blank-session event is buffered so it can adopt the next real id inside the gap, which
  # means the caller owns flushing whatever state still holds when it stops feeding pages.
  def sessionize_events(events, project_id, state = {}, prior_sessions: {})
    rows = []
    affected_sessions = Set.new
    current_visitor = state[:current_visitor]
    session_counter = state[:session_counter] || 0
    last_ts = state[:last_ts]
    pending = state[:pending] || []
    pending_last_ts = state[:pending_last_ts]

    flush = lambda do
      flushed, sessions = flush_pending_rows(pending)
      rows.concat(flushed)
      affected_sessions.merge(sessions)
      pending = []
      pending_last_ts = nil
    end

    events.each do |event|
      vid = event['visitor_id']

      if vid != current_visitor
        flush.call
        current_visitor = vid
        prior = prior_sessions[vid]
        session_counter = prior ? prior[:session_counter] : 0
        last_ts = prior ? prior[:last_ts] : nil
      end

      ts = ensure_time(event['created_at'])
      existing_session = event['session_id'].to_s

      if existing_session.present?
        resolved_session = existing_session.first(MAX_SESSION_ID_LENGTH)

        if pending.any? && (ts - pending_last_ts) <= INACTIVITY_GAP_SECONDS
          pending.each { |row| row[:session_id] = resolved_session }
          rows.concat(pending)
          pending = []
          pending_last_ts = nil
        else
          flush.call
        end

        affected_sessions << resolved_session
        rows << build_session_row(event, project_id, resolved_session, ts)
      else
        flush.call if pending.any? && (ts - pending_last_ts) > INACTIVITY_GAP_SECONDS
        session_counter += 1 if last_ts && (ts - last_ts) > INACTIVITY_GAP_SECONDS
        pending << build_session_row(event, project_id, "synth_#{vid}_#{session_counter}", ts)
        pending_last_ts = ts
      end

      last_ts = ts
    end

    new_state = { current_visitor: current_visitor, session_counter: session_counter,
                  last_ts: last_ts, pending: pending, pending_last_ts: pending_last_ts }
    [rows, affected_sessions, new_state]
  end

  # Buffered rows already carry the synthetic id they fall back to.
  def flush_pending_rows(pending)
    return [[], []] if pending.blank?

    [pending, pending.map { |row| row[:session_id] }.uniq]
  end

  def build_session_row(event, project_id, session_id, occurred_at)
    {
      project_id: project_id,
      session_id: session_id,
      visitor_id: event['visitor_id'],
      device_id: event['device_id'],
      event_id: event['event_id'].to_s,
      event_date: occurred_at.to_date.to_s,
      event_type: event['event_type'].to_s,
      event_name: event['event_name'].to_s,
      screen_name: event['screen_name'].to_s,
      platform: event['platform'].to_s,
      app_version: event['app_version'].to_s,
      country: event['country'].to_s,
      city: event['city'].to_s,
      device_model: event['device_model'].to_s,
      os: event['os'].to_s,
      os_version: event['os_version'].to_s,
      link_id: event['link_id'].to_i,
      campaign_id: event['campaign_id'].to_i,
      tracking_source: event['tracking_source'].to_s,
      tracking_medium: event['tracking_medium'].to_s,
      tracking_campaign: event['tracking_campaign'].to_s,
      ads_platform: event['ads_platform'].to_s,
      sdk_identifier: event['sdk_identifier'].to_s,
      engagement_time: event['engagement_time'].to_i,
      properties: event['properties'].is_a?(Hash) ? event['properties'] : {},
      sdk_generated: event['sdk_generated'].to_i,
      link_visitor_id: event['link_visitor_id'].to_i,
      created_at: format_timestamp(occurred_at)
    }
  end

  def format_timestamp(value)
    case value
    when Time, ActiveSupport::TimeWithZone
      value.utc.strftime(Analytics::QueryHelpers::CH_DATETIME_FMT)
    when String
      value
    else
      value.to_s
    end
  end

  # CH driver may return DateTime64 as Time or String depending on version.
  def ensure_time(value)
    case value
    when Time, ActiveSupport::TimeWithZone
      value
    when String
      Time.parse(value)
    when Numeric
      Time.at(value)
    else
      Time.parse(value.to_s)
    end
  end
end
