# frozen_string_literal: true

module Analytics
  module EventsQueryService
    extend QueryHelpers

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 200
    MIN_RECENT_CANDIDATES = 1_000
    MAX_RECENT_CANDIDATES = 5_000
    FIELD_CACHE_TTL = 10.minutes
    FIELD_LOOKBACK_DAYS = 90 # bounds field/value discovery scans to recent data (avoids full-history scan)

    # Top-level event attributes that can be filtered on.
    # Integer fields (visitor_id, link_id, campaign_id) are included here so
    # field_column_expression recognises them and build_filter_clauses routes
    # them through INTEGER_FILTER_FIELDS for proper type handling.
    ALLOWED_FIELDS = %w[
      event_type event_name screen_name platform app_version country city
      device_model os os_version tracking_source tracking_medium tracking_campaign
      ads_platform sdk_identifier session_id visitor_id link_id campaign_id
    ].freeze

    # Sortable columns for the list endpoint.
    SORTABLE_COLUMNS = %w[created_at event_type event_name platform].freeze

    # Namespace for visitor sdk_attributes filters (event-time snapshot, not current profile).
    USER_ATTR_PREFIX = 'user.'

    # Columns returned by the list endpoint. Excludes PII (ip, remote_ip),
    # internal fields (vendor_id, build, path), and large JSON blobs that
    # aren't needed for the event table view. The properties key is kept in the
    # response shape, but deliberately not read from ClickHouse here; use #find
    # for the full single-event payload.
    LIST_ATTRIBUTE_COLUMNS = %w[
      event_id project_id event_type event_name screen_name
      visitor_id device_id link_id campaign_id session_id
      platform app_version device_model os os_version
      country city
      tracking_source tracking_medium tracking_campaign ads_platform
      sdk_identifier engagement_time created_at
    ].freeze
    LIST_COLUMNS = (LIST_ATTRIBUTE_COLUMNS + ['NULL AS properties']).freeze

    # --- Public API ---

    # Paginated event list with optional filters.
    # Returns { data: [...], next_cursor: String|nil, total_count: Integer|nil }
    # total_count is an Integer when include_count is requested and the count query
    # succeeds; it is nil when the count is not requested or when the count query
    # degraded (e.g. timed out / QueryTooHeavy) — rows are still returned.
    def self.list(project_id, start_date:, end_date:, cursor: nil, limit: DEFAULT_LIMIT,
                  sort_by: 'created_at', sort_order: 'desc', search: nil, filters: [],
                  include_count: false)
      pid = Integer(project_id)
      limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      sort_col = SORTABLE_COLUMNS.include?(sort_by) ? sort_by : 'created_at'
      sort_dir = sort_order == 'asc' ? 'ASC' : 'DESC'

      base_where_clauses = base_where(pid, start_date, end_date)
      filter_where_clauses = build_event_filters(filters)
      search_where_clause = search_clause(search) if search.present?
      latest_where_sql = base_where_clauses.join(' AND ')
      fast_recent_path = filter_where_clauses.empty? && search_where_clause.nil? && sort_col == 'created_at'
      if fast_recent_path
        candidate_limit = [[limit * 20, MIN_RECENT_CANDIDATES].max, MAX_RECENT_CANDIDATES].min
        candidate_where_clauses = base_where_clauses + cursor_clauses(cursor, sort_dir)
        latest_where_sql = [
          latest_where_sql,
          "event_id IN (SELECT event_id FROM events WHERE #{candidate_where_clauses.join(' AND ')} " \
          "ORDER BY created_at #{sort_dir}, event_id #{sort_dir}, ingested_at DESC " \
          "LIMIT 1 BY event_id LIMIT #{candidate_limit})"
        ].join(' AND ')
      elsif filter_where_clauses.any? || search_where_clause
        candidate_where_clauses = base_where_clauses + filter_where_clauses
        candidate_where_clauses << search_where_clause if search_where_clause
        latest_where_sql = [
          latest_where_sql,
          "event_id IN (SELECT DISTINCT event_id FROM events WHERE #{candidate_where_clauses.join(' AND ')})"
        ].join(' AND ')
      end

      list_where_clauses = []
      list_where_clauses.concat(filter_where_clauses)
      list_where_clauses << search_where_clause if search_where_clause
      list_where_clauses.concat(cursor_clauses(cursor, sort_dir))
      list_where_sql = list_where_clauses.any? ? "WHERE #{list_where_clauses.join(' AND ')}" : ''

      count_where_clauses = base_where_clauses + filter_where_clauses
      count_where_clauses << search_where_clause if search_where_clause
      count_where_sql = count_where_clauses.join(' AND ')
      latest_columns = LIST_ATTRIBUTE_COLUMNS.map do |col|
        col == 'platform' ? "#{ClickhouseReadService::NORMALIZED_PLATFORM_SQL} AS platform" : col
      end
      latest_columns << 'ingested_at'
      latest_columns.concat(dynamic_filter_columns(filters))

      data = with_guard(<<~SQL).to_a
        SELECT #{LIST_COLUMNS.join(', ')}
        FROM (
          SELECT #{latest_columns.join(', ')}
          FROM events
          WHERE #{latest_where_sql}
          ORDER BY event_id ASC, ingested_at DESC
          LIMIT 1 BY event_id
        )
        #{list_where_sql}
        ORDER BY #{sort_col} #{sort_dir}, event_id #{sort_dir}, ingested_at DESC
        LIMIT #{limit + 1}
      SQL

      has_more = data.size > limit
      data = data.first(limit)
      next_cursor = has_more ? encode_cursor(data.last) : nil

      total_count = nil
      if include_count
        begin
          total_count = with_guard("SELECT count() FROM events FINAL WHERE #{count_where_sql}").first.values.first
        rescue Analytics::QueryTooHeavy
          total_count = nil # rows already fetched — don't fail a good page
        end
      end

      { data: data, next_cursor: next_cursor, total_count: total_count }
    rescue StandardError => e
      log_query_failure(:list, e)
      { data: [], next_cursor: nil, total_count: 0 }
    end

    # Find a single event by event_id.
    def self.find(project_id, event_id:)
      pid = Integer(project_id)
      eid = sanitize_string(event_id.to_s)

      with_guard(<<~SQL).first
        SELECT * REPLACE (#{ClickhouseReadService::NORMALIZED_PLATFORM_SQL} AS platform)
        FROM events FINAL
        WHERE project_id = #{pid}
          AND event_id = '#{eid}'
        LIMIT 1
      SQL
    rescue StandardError => e
      log_query_failure(:find, e)
      nil
    end

    # Time-bucketed volume histogram.
    # Returns { buckets: [{ bucket: "2026-05-01", count: N }, ...] }
    def self.volume(project_id, start_date:, end_date:, bucket: nil, search: nil, filters: [], timezone: 'UTC')
      pid = Integer(project_id)
      sd = sanitize_date_value(start_date)
      # Exclusive upper bound: the last included day is a second earlier.
      ed = sanitize_date_value(end_date.is_a?(Time) ? end_date - 1 : end_date)
      bucket_expr = resolve_bucket(bucket, sd, ed, resolve_timezone(timezone))

      where_clauses = base_where(pid, start_date, end_date)
      where_clauses.concat(build_event_filters(filters))
      where_clauses << search_clause(search) if search.present?
      where_sql = where_clauses.join(' AND ')

      rows = with_guard(<<~SQL).to_a
        SELECT
          #{bucket_expr} AS bucket,
          count() AS count
        FROM events FINAL
        WHERE #{where_sql}
        GROUP BY bucket
        ORDER BY bucket
      SQL

      { buckets: rows }
    rescue StandardError => e
      log_query_failure(:volume, e)
      { buckets: [] }
    end

    # Distinct values for a given field (typeahead support).
    def self.field_values(project_id, field:, q: nil, limit: DEFAULT_LIMIT, cursor: nil,
                          start_date: nil, end_date: nil)
      pid = Integer(project_id)
      limit = [[Integer(limit), 1].max, MAX_LIMIT].min

      # Integer ID fields — resolve to names via PG with cursor pagination.
      # DISTINCT value discovery is idempotent to row duplicates, so no FINAL is
      # needed even though events is a ReplacingMergeTree.
      if %w[link_id campaign_id].include?(field.to_s)
        return resolve_id_field(pid, field.to_s, q: q, limit: limit,
                                ch_table: 'events', ch_final: false, cursor: cursor)
      end

      if field.to_s == 'visitor_id'
        return resolve_visitor_field(pid, q: q, limit: limit,
                                     ch_table: 'events', ch_final: false, cursor: cursor)
      end

      col_expr = field_column_expression(field)
      return { values: [] } unless col_expr

      where = +"project_id = #{pid}"
      where << " AND #{field_date_clause(start_date, end_date)}"
      if q.present?
        where << " AND lower(#{col_expr}) LIKE '%#{sanitize_like(q.downcase)}%'"
      end
      where << " AND #{col_expr} != ''"
      if (after = decode_value_cursor(cursor))
        where << " AND #{col_expr} > '#{sanitize_string(after)}'"
      end

      rows = with_guard(<<~SQL)
        SELECT DISTINCT #{col_expr} AS value
        FROM events
        WHERE #{where}
        ORDER BY value
        LIMIT #{limit}
      SQL

      values = rows.map { |r| r['value'] }
      { values: values, next_cursor: values.size == limit ? encode_value_cursor(values.last) : nil }
    rescue StandardError => e
      log_query_failure(:field_values, e)
      { values: [] }
    end

    # Available fields: static attributes + dynamic property and user-attribute keys.
    # Key discovery is cached for 10 minutes (JSONAllPaths is expensive).
    def self.fields(project_id, start_date: nil, end_date: nil)
      pid = Integer(project_id)

      static = ALLOWED_FIELDS.map { |f| { name: f, type: 'attribute' } }

      cache_key = "analytics:fields:v2:#{pid}:#{start_date}:#{end_date}"
      property_keys, user_attr_keys = Rails.cache.fetch(cache_key, expires_in: FIELD_CACHE_TTL) do
        %w[properties sdk_attributes].map do |col|
          rows = with_guard(<<~SQL)
            SELECT DISTINCT arrayJoin(JSONAllPaths(#{col})) AS key_name
            FROM events
            WHERE project_id = #{pid}
              AND #{field_date_clause(start_date, end_date)}
            LIMIT 100
          SQL
          rows.map { |r| r['key_name'] }
        end
      end

      # Picker set == filterable set: only offer keys that field_column_expression
      # will actually accept, so the FE never surfaces an unfilterable key.
      # A property sharing a static name (e.g. screen_name) filters via the column — offer it once.
      dynamic = property_keys
                .select { |k| valid_property_key?(k) && ALLOWED_FIELDS.exclude?(k) }
                .map { |k| { name: k, type: 'property' } }
      user_dynamic = user_attr_keys
                     .select { |k| valid_property_key?(k) }
                     .map { |k| { name: "#{USER_ATTR_PREFIX}#{k}", type: 'user_attribute' } }

      { fields: static + dynamic + user_dynamic }
    rescue StandardError => e
      log_query_failure(:fields, e)
      { fields: ALLOWED_FIELDS.map { |f| { name: f, type: 'attribute' } } }
    end

    # --- Private helpers ---

    def self.base_where(project_id, start_date, end_date)
      [
        "project_id = #{Integer(project_id)}",
        # 'UTC' is required: toDateTime64 otherwise parses in the server's zone and shifts the range.
        "created_at >= toDateTime64('#{to_ch_time(start_date)}', 3, 'UTC')",
        "created_at < toDateTime64('#{to_ch_time(end_date, day_end: true)}', 3, 'UTC')"
      ]
    end
    private_class_method :base_where

    DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/

    # Half-open upper bound: a bare date spans its whole UTC day, an instant is exclusive.
    def self.to_ch_time(value, day_end: false)
      bump = day_end ? 1 : 0
      time = case value
             when DateTime then value.to_time.utc # DateTime is a Date, and its #to_time takes no args
             when Time, ActiveSupport::TimeWithZone then value.utc
             when Date then (value + bump).to_time(:utc)
             else
               str = value.to_s
               str.match?(DATE_ONLY) ? (Date.parse(str) + bump).to_time(:utc) : Time.parse(str).utc
             end
      time.strftime(QueryHelpers::CH_DATETIME_FMT)
    end
    private_class_method :to_ch_time

    # Bounds field/value discovery to a date window: the explicit request range when
    # given, else the recent default — never an unbounded full-history scan.
    def self.field_date_clause(start_date, end_date)
      if start_date && end_date
        "toDate(created_at) >= '#{sanitize_date(start_date)}' AND toDate(created_at) <= '#{sanitize_date(end_date)}'"
      else
        "created_at >= now() - INTERVAL #{FIELD_LOOKBACK_DAYS} DAY"
      end
    end
    private_class_method :field_date_clause

    # Builds filter clauses for events, combining shared QueryHelpers
    # integer/string dispatch for standard fields with native JSON subcolumn
    # casts for dynamic property fields.
    def self.build_event_filters(filters)
      return [] if filters.blank?

      parsed = parse_filters(filters)
      attr_filters, prop_filters = parsed.partition { |f| ALLOWED_FIELDS.include?(f['field'].to_s) }

      clauses = build_filter_clauses(attr_filters, allowed_fields: ALLOWED_FIELDS)

      # Property filters: the column expression is a native JSON subcolumn cast,
      # but the comparison logic is identical to string filters.
      prop_filters.each do |filter|
        col = field_column_expression(filter['field'].to_s)
        next unless col

        clause = build_string_filter_clause('', col, filter['operator'].to_s, filter['value'])
        clauses << clause if clause
      end

      clauses
    end
    private_class_method :build_event_filters

    # JSON columns the inner select must project so the outer WHERE can apply dynamic filters.
    def self.dynamic_filter_columns(filters)
      return [] if filters.blank?

      parse_filters(filters).filter_map do |filter|
        field = filter['field'].to_s
        next if ALLOWED_FIELDS.include?(field)

        if field.start_with?(USER_ATTR_PREFIX)
          'sdk_attributes' if valid_property_key?(field.delete_prefix(USER_ATTR_PREFIX))
        elsif valid_property_key?(field)
          'properties'
        end
      end.uniq
    end
    private_class_method :dynamic_filter_columns

    # Public: the field-values controller allowlist accepts "user.<key>" via this.
    def self.user_attribute_field?(field)
      field = field.to_s
      field.start_with?(USER_ATTR_PREFIX) && valid_property_key?(field.delete_prefix(USER_ATTR_PREFIX))
    end

    # The key is interpolated as a bare backtick-quoted identifier, so this allowlist
    # is the SOLE injection defense. Reject backtick (closes the quote), BACKSLASH
    # (escapes the closing backtick — verified cross-tenant injection vector), space,
    # and control chars (0x00-0x20, 0x7f). NEVER loosen this without re-proving identifier
    # quoting cannot be broken. See the security regression test.
    INVALID_PROPERTY_KEY = /[\x00-\x20\\`\x7f]/

    # A property key is filterable iff it is a non-empty, <=256-byte String free
    # of backtick/space/control chars. Kept public: `fields` (picker) and tests
    # call it so the picker set == the filterable set.
    def self.valid_property_key?(key)
      key.is_a?(String) && key.bytesize.between?(1, 256) && !key.match?(INVALID_PROPERTY_KEY)
    end

    # Returns the SQL column expression for a field name.
    # Attribute fields → column name directly. Property fields → native JSON
    # subcolumn cast (reads only that path's column, not the whole blob).
    # Returns nil for invalid keys so callers skip them (no clause / no value query).
    def self.field_column_expression(field)
      field = field.to_s
      return ClickhouseReadService::NORMALIZED_PLATFORM_SQL if field == 'platform'
      return field if ALLOWED_FIELDS.include?(field)

      if field.start_with?(USER_ATTR_PREFIX)
        key = field.delete_prefix(USER_ATTR_PREFIX)
        return unless valid_property_key?(key)

        return "CAST(sdk_attributes.`#{key}` AS String)"
      end
      return unless valid_property_key?(field)

      "CAST(properties.`#{field}` AS String)"
    end
    private_class_method :field_column_expression

    def self.search_clause(search)
      escaped = sanitize_like(search.downcase)
      "(lower(event_name) LIKE '%#{escaped}%' OR lower(screen_name) LIKE '%#{escaped}%' OR lower(event_type) LIKE '%#{escaped}%')"
    end
    private_class_method :search_clause

    def self.cursor_clauses(cursor, sort_dir)
      return [] unless cursor.present?

      decoded = decode_cursor(cursor)
      return [] unless decoded

      ts = sanitize_string(decoded['t'].to_s)
      eid = sanitize_string(decoded['id'].to_s)
      op = sort_dir == 'DESC' ? '<' : '>'

      ["(created_at #{op} '#{ts}' OR (created_at = '#{ts}' AND event_id #{op} '#{eid}'))"]
    end
    private_class_method :cursor_clauses

    def self.encode_cursor(row)
      return nil unless row

      ts = row['created_at']
      formatted_ts = case ts
                     when Time, ActiveSupport::TimeWithZone
                       ts.utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
                     else
                       ts.to_s
                     end
      payload = { t: formatted_ts, id: row['event_id'].to_s }
      Base64.urlsafe_encode64(payload.to_json, padding: false)
    end
    private_class_method :encode_cursor

    def self.encode_value_cursor(value)
      return nil if value.nil?

      Base64.urlsafe_encode64(value.to_s, padding: false)
    end
    private_class_method :encode_value_cursor

    def self.decode_value_cursor(cursor)
      return nil if cursor.blank?

      Base64.urlsafe_decode64(cursor)
    rescue ArgumentError
      nil
    end
    private_class_method :decode_value_cursor

    def self.decode_cursor(cursor)
      json = Base64.urlsafe_decode64(cursor)
      parsed = JSON.parse(json)
      return nil unless parsed['t'].present? && parsed['id'].present?

      parsed
    rescue ArgumentError, JSON::ParserError
      nil
    end
    private_class_method :decode_cursor

    def self.resolve_bucket(bucket, start_date, end_date, timezone)
      days = (Date.parse(end_date) - Date.parse(start_date)).to_i

      interval = bucket || case days
                           when 0..2 then 'hour'
                           when 3..30 then 'day'
                           when 31..90 then 'week'
                           else 'month'
                           end

      # Metadata-only reinterpretation; kept out of WHERE so created_at pruning is unaffected.
      local = "toTimeZone(created_at, '#{timezone}')"

      case interval
      when 'hour' then "formatDateTime(#{local}, '%Y-%m-%d %H:00:00')"
      when 'week' then "toStartOfWeek(toDate(#{local}))"
      when 'month' then "toStartOfMonth(toDate(#{local}))"
      else "toDate(#{local})"
      end
    end
    private_class_method :resolve_bucket

    # Guards SQL interpolation: anything TZInfo rejects never reaches the query.
    def self.resolve_timezone(timezone)
      TZInfo::Timezone.get(timezone.to_s).identifier
    rescue StandardError
      'UTC'
    end
    private_class_method :resolve_timezone

  end
end
