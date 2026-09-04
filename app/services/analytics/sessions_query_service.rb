# frozen_string_literal: true

require 'base64' # Ruby 3.4+ no longer auto-loads the base64 stdlib; the opaque key/cursor depend on it.

module Analytics
  # Explore-only Sessions reader: list + detail over session_summary / session_events.
  # A session's identity is the FULL triple (project_id, session_id, visitor_id) —
  # SDK session_ids are arbitrary and not unique on their own. No screen-path /
  # funnel logic lives here.
  module SessionsQueryService
    extend QueryHelpers

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200

    LIST_COLUMNS = %w[
      session_id visitor_id event_date started_at ended_at duration_ms event_count
      platform app_version country device_model link_id campaign_id
      tracking_source has_conversion revenue_usd_cents
    ].map { |col| col == 'platform' ? "#{ClickhouseReadService::NORMALIZED_PLATFORM_SQL} AS platform" : col }.freeze

    FILTER_FIELDS = %w[platform country link_id campaign_id has_conversion app_version].freeze

    # Returns { data: [...], next_cursor: String|nil }
    # `source` (optional) is a derived category — one of QueryHelpers::SOURCE_CATEGORIES —
    # filtered via source_where_clause, NOT through build_filter_clauses.
    def self.list(project_id, start_date:, end_date:, cursor: nil, limit: DEFAULT_LIMIT, filters: [], source: nil)
      pid = Integer(project_id)
      limit = [[Integer(limit), 1].max, MAX_LIMIT].min

      where = base_where(pid, start_date, end_date)
      where.concat(build_filter_clauses(parse_filters(filters), allowed_fields: FILTER_FIELDS))
      if source.present? && QueryHelpers::SOURCE_CATEGORIES.include?(source.to_s)
        clause = source_where_clause(source.to_s)
        where << clause if clause
      end
      where.concat(cursor_clauses(cursor))
      where_sql = where.join(' AND ')

      data = with_guard(<<~SQL).to_a
        SELECT #{LIST_COLUMNS.join(', ')},
               #{source_type_expr} AS source
        FROM session_summary FINAL
        WHERE #{where_sql}
        ORDER BY started_at DESC, session_id DESC, visitor_id DESC
        LIMIT #{limit + 1}
      SQL

      has_more = data.size > limit
      data = data.first(limit)
      next_cursor = has_more ? encode_cursor(data.last) : nil

      # Inject an opaque, URL-safe detail key carrying the FULL identity
      # (session_id + visitor_id + event_date). SDK session_ids are arbitrary and
      # not unique on their own, and the SAME visitor can reuse one across days —
      # event_date is part of session_summary's ReplacingMergeTree dedup key, so it
      # is required to address exactly one session instance.
      data.each { |r| r['id'] = encode_key(r['session_id'], r['visitor_id'], r['event_date']) }

      { data: data, next_cursor: next_cursor }
    rescue StandardError => e
      log_query_failure(:list, e)
      { data: [], next_cursor: nil }
    end

    # Returns { session: {...}, events: [...] } or nil if not found in THIS project.
    # Identity is the FULL dedup key (project_id, session_id, visitor_id, event_date) —
    # visitor_id stops two visitors sharing a session_id from cross-contaminating, and
    # event_date disambiguates the same visitor reusing one session_id across days.
    # Events are bounded to the matched session's [started_at, ended_at] window so a
    # reused id never merges another day's events into this instance.
    def self.find(project_id, session_id:, visitor_id:, event_date:)
      pid = Integer(project_id)
      sid = sanitize_string(session_id.to_s)
      vid = Integer(visitor_id)
      edate = sanitize_date_value(event_date)

      session = with_guard(<<~SQL).to_a.first
        SELECT #{LIST_COLUMNS.join(', ')},
               #{source_type_expr} AS source
        FROM session_summary FINAL
        WHERE project_id = #{pid} AND session_id = '#{sid}'
          AND visitor_id = #{vid} AND event_date = '#{edate}'
        LIMIT 1
      SQL
      return nil unless session

      started = ch_datetime(session['started_at'])
      ended = ch_datetime(session['ended_at'])
      events = with_guard(<<~SQL).to_a
        SELECT event_id, event_type, event_name, screen_name, created_at,
               #{ClickhouseReadService::NORMALIZED_PLATFORM_SQL} AS platform,
               app_version, country, link_id, campaign_id, engagement_time
        FROM session_events
        WHERE project_id = #{pid} AND session_id = '#{sid}' AND visitor_id = #{vid}
          AND created_at >= '#{started}' AND created_at <= '#{ended}'
        ORDER BY created_at ASC
      SQL

      { session: session, events: events }
    rescue StandardError => e
      log_query_failure(:find, e)
      nil
    end

    # Opaque detail identity carrying the full dedup key. Base64url(JSON) → URL-safe
    # and slash-free, so it rides safely in a `:id` path segment regardless of the
    # raw session_id bytes.
    def self.encode_key(session_id, visitor_id, event_date)
      Base64.urlsafe_encode64(
        { s: session_id.to_s, v: visitor_id.to_i, d: event_date.to_s }.to_json, padding: false
      )
    end

    def self.decode_key(key)
      parsed = JSON.parse(Base64.urlsafe_decode64(key.to_s))
      sid = parsed['s']
      vid = parsed['v']
      edate = parsed['d']
      return nil if sid.nil? || sid.to_s.empty? || vid.nil? || edate.nil? || edate.to_s.empty?

      # Validate the date HERE so a forged key with a bad date degrades to the
      # controller's 400, instead of reaching find() and raising Date::Error
      # (a PROPAGATED_ERROR → uncaught → 500).
      Date.iso8601(edate.to_s)

      { session_id: sid.to_s, visitor_id: Integer(vid), event_date: edate.to_s }
    rescue ArgumentError, JSON::ParserError, TypeError # Date::Error ⊂ ArgumentError
      nil
    end

    def self.base_where(pid, start_date, end_date)
      [
        "project_id = #{Integer(pid)}",
        "event_date >= '#{sanitize_date_value(start_date)}'",
        "event_date <= '#{sanitize_date_value(end_date)}'"
      ]
    end
    private_class_method :base_where

    def self.cursor_clauses(cursor)
      return [] unless cursor.present?

      decoded = decode_cursor(cursor)
      return [] unless decoded

      # Cursor must compare the FULL ordering tuple (started_at, session_id, visitor_id).
      # Two visitors can share both session_id and started_at, so comparing only the
      # first two could skip or duplicate a row at the page boundary.
      ts = sanitize_string(decoded['t'].to_s)
      sid = sanitize_string(decoded['s'].to_s)
      vid = Integer(decoded['v'])
      [
        "(started_at < '#{ts}' " \
        "OR (started_at = '#{ts}' AND session_id < '#{sid}') " \
        "OR (started_at = '#{ts}' AND session_id = '#{sid}' AND visitor_id < #{vid}))"
      ]
    rescue ArgumentError
      []
    end
    private_class_method :cursor_clauses

    def self.encode_cursor(row)
      return nil unless row

      Base64.urlsafe_encode64(
        { t: ch_datetime(row['started_at']), s: row['session_id'].to_s, v: row['visitor_id'].to_i }.to_json,
        padding: false
      )
    end
    private_class_method :encode_cursor

    # Render a CH DateTime64 value (Time from the driver, or already a string) into
    # the canonical 'YYYY-MM-DD HH:MM:SS.mmm' literal, sanitized for interpolation.
    def self.ch_datetime(value)
      str = value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) ? value.utc.strftime('%Y-%m-%d %H:%M:%S.%3N') : value.to_s
      sanitize_string(str)
    end
    private_class_method :ch_datetime

    def self.decode_cursor(cursor)
      parsed = JSON.parse(Base64.urlsafe_decode64(cursor))
      return nil unless parsed['t'].present? && parsed['s'].present? && !parsed['v'].nil?

      parsed
    rescue ArgumentError, JSON::ParserError
      nil
    end
    private_class_method :decode_cursor
  end
end
