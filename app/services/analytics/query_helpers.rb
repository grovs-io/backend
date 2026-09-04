# frozen_string_literal: true

module Analytics
  # Shared sanitization and utility helpers for CH-backed analytics services.
  # Include in a module, then call via self.sanitize_string(...) etc.
  module QueryHelpers
    # Unavailable must reach the controller's 503 — a broad rescue here would serve empty as success.
    PROPAGATED_ERRORS = [ArgumentError, Date::Error, Analytics::QueryTooHeavy,
                         Clickhouse::Unavailable, Clickhouse::Stale, RevenueLedger::Unavailable].freeze
    CH_DATETIME_FMT = '%Y-%m-%d %H:%M:%S.%3N'
    ALLOWED_CH_TABLES = %w[events events session_events session_summary].freeze
    # Columns allowed to be interpolated as a SELECT/WHERE identifier in the id resolvers.
    RESOLVABLE_ID_COLUMNS = %w[link_id campaign_id].freeze

    GUARD = "SETTINGS max_execution_time = #{Config::QUERY_MAX_EXECUTION_SEC}, " \
            "max_memory_usage = #{Config::QUERY_MAX_MEMORY_BYTES}"
    # Code 159 = timeout, Code 241 = memory cap. click_house-client raises one
    # undifferentiated DatabaseError, so detect by message; never mis-tag real bugs.
    HEAVY = /Code:\s*(159|241)\b|TIMEOUT_EXCEEDED|MEMORY_LIMIT_EXCEEDED/

    # Canonical source category names used across all analytics services.
    SOURCE_CATEGORIES = %w[campaigns referrals api_links links organic].freeze

    SOURCE_DISPLAY_NAMES = {
      'campaigns' => 'Campaigns', 'referrals' => 'Referrals',
      'api_links' => 'API Links', 'links' => 'Links', 'organic' => 'Organic'
    }.freeze

    private

    # Runs a read query with execution-time/memory guards. Maps CH timeout/memory
    # errors to Analytics::QueryTooHeavy (→ 422); any other DatabaseError is re-raised
    # unchanged so genuine bugs still surface (logged + empty shape via log_query_failure).
    # Only a transport READ timeout also maps to QueryTooHeavy: the query outran even the
    # HTTP read window, so it is too-heavy, not a 500. Open/connection timeouts (and
    # connection-refused/reset/EOF) are left to propagate — those are availability
    # problems, not heavy queries. Note Net::OpenTimeout < Timeout::Error, so the rescue
    # is narrowed to Net::ReadTimeout to avoid mis-tagging an open timeout as too-heavy.
    def with_guard(sql)
      Clickhouse.with { |c| c.select_all("#{sql.strip.chomp(';')}\n#{GUARD}") }
    rescue ClickHouse::Client::DatabaseError => e
      raise Analytics::QueryTooHeavy, e.message if e.message.match?(HEAVY)

      raise
    rescue Net::ReadTimeout => e
      raise Analytics::QueryTooHeavy, e.message
    end

    def format_number(num)
      return '0' if num.nil? || num.zero?
      return num.to_s if num.negative?

      abs = num.abs
      if abs < 1_000
        num.to_s
      elsif abs < 1_000_000
        v = (num / 1_000.0).round(1)
        v >= 1_000 ? "#{(num / 1_000_000.0).round(1)}M" : "#{v}K"
      elsif abs < 1_000_000_000
        v = (num / 1_000_000.0).round(1)
        v >= 1_000 ? "#{(num / 1_000_000_000.0).round(1)}B" : "#{v}M"
      else
        "#{(num / 1_000_000_000.0).round(1)}B"
      end
    end

    def format_duration_ms(millis)
      return nil if millis.nil? || millis <= 0

      secs = (millis / 1000.0).round
      if secs < 60 then "#{secs}s"
      elsif secs < 3600 then "#{secs / 60}m #{secs % 60}s"
      else "#{secs / 3600}h #{(secs % 3600) / 60}m"
      end
    end

    def display_source_name(raw)
      SOURCE_DISPLAY_NAMES[raw] || raw.to_s.titleize
    end

    def safe_percent(numerator, denominator)
      return 0.0 if denominator.nil? || denominator.zero?

      ((numerator.to_f / denominator) * 100).round(1)
    end

    # Escapes a value for safe interpolation into a CH single-quoted string literal.
    # CH recognises these escape sequences inside strings:
    #   \\ \' \b \f \r \n \t \0 \a \v \xHH
    # Escaping \ first neutralises all backslash-based sequences; \' handles quotes.
    # Control characters (\0 \b \n \r \t) are escaped to prevent raw bytes in queries.
    # Uses block form of gsub to avoid Ruby replacement-string interpretation issues.
    def sanitize_string(value)
      value.to_s
           .gsub('\\') { '\\\\' }
           .gsub("'") { "\\'" }
           .gsub("\0") { '\\0' }
           .gsub("\b") { '\\b' }
           .gsub("\n") { '\\n' }
           .gsub("\r") { '\\r' }
           .gsub("\t") { '\\t' }
    end

    def sanitize_date(value)
      Date.parse(value.to_s).strftime('%Y-%m-%d')
    end

    # Handles Date/Time objects without reparsing.
    def sanitize_date_value(value)
      case value
      when Date, Time, ActiveSupport::TimeWithZone
        value.to_date.strftime('%Y-%m-%d')
      else
        Date.parse(value.to_s).strftime('%Y-%m-%d')
      end
    end

    # For LIKE patterns, escape wildcards before sanitize_string so the
    # backslashes survive CH string-literal parsing: \% in source → \\% in
    # the SQL literal → \% after CH string parse → literal % for the LIKE engine.
    def sanitize_like(value)
      escaped = value.to_s.gsub('%') { '\\%' }.gsub('_') { '\\_' }
      sanitize_string(escaped)
    end

    # Normalized like PG's platform_for_metrics: raw rows hold mac/windows/desktop.
    def platform_where(platform, table: nil)
      return '' unless platform.present?

      col = "#{table ? "#{table}." : ''}platform"
      value = ClickhouseReadService.normalize_platform_value(platform)
      "AND if(#{col} IN ('ios', 'android'), #{col}, 'web') = '#{sanitize_string(value)}'"
    end

    def parse_filters(filters)
      decoded = filters.is_a?(String) ? JSON.parse(filters) : filters
      # A lone filter object, not the {"event_type":"open"} shorthand — reading it as the
      # latter would name its own keys as fields and silently return everything.
      decoded = [decoded] if decoded.respond_to?(:key?) && (decoded.key?('field') || decoded.key?('f'))
      parsed = case decoded
               # key? not is_a?(Hash): ActionController::Parameters is neither a Hash nor an Array.
               when Array then decoded.select { |f| f.respond_to?(:key?) }
               when Hash then decoded.map { |field, value| { 'field' => field.to_s, 'operator' => 'is', 'value' => value } }
               else []
               end
      # Normalize shorthand keys (f/o/v) to full names (field/operator/value)
      parsed.first(MAX_FILTERS).map do |f|
        {
          'field'    => f['field']    || f['f'],
          'operator' => f['operator'] || f['o'],
          'value'    => f['value']    || f['v']
        }
      end
    rescue JSON::ParserError
      []
    end
    # Expose at module level for callers outside the mixin (controllers).
    module_function :parse_filters

    INTEGER_FILTER_FIELDS = %w[link_id campaign_id visitor_id].freeze
    BOOLEAN_FILTER_FIELDS = %w[has_conversion].freeze
    MAX_FILTERS = 25         # cap filter count to bound WHERE-clause size
    MAX_FILTER_VALUES = 100  # cap IN(...) list length per filter

    def build_filter_clauses(filters, allowed_fields:, table: nil)
      return [] if filters.blank?

      prefix = table ? "#{table}." : ''
      clauses = []
      filters.each do |f|
        field = f['field'].to_s
        op    = f['operator'].to_s
        value = f['value']
        value = value.first(MAX_FILTER_VALUES) if value.is_a?(Array)
        next if field.blank? || op.blank?
        next unless allowed_fields.include?(field)

        clause = if BOOLEAN_FILTER_FIELDS.include?(field)
                   bool_val = %w[true 1].include?(value.to_s.downcase) ? 1 : 0
                   bool_val = 1 - bool_val if op == 'is_not'
                   "#{prefix}#{field} = #{bool_val}"
                 elsif INTEGER_FILTER_FIELDS.include?(field)
                   build_integer_filter_clause(prefix, field, op, value)
                 elsif field == 'platform'
                   build_platform_filter_clause(prefix, op, value)
                 else
                   build_string_filter_clause(prefix, field, op, value)
                 end
        clauses << clause if clause
      end
      clauses
    end

    # Normalized-to-normalized comparison so 'web' matches raw mac/windows/desktop rows.
    def build_platform_filter_clause(prefix, operator, value)
      col = ClickhouseReadService.normalized_platform_sql(prefix)
      value = if value.is_a?(Array)
                value.map { |v| ClickhouseReadService.normalize_platform_value(v) }.uniq
              else
                ClickhouseReadService.normalize_platform_value(value)
              end
      build_string_filter_clause('', col, operator, value)
    end

    def build_integer_filter_clause(prefix, field, operator, value)
      case operator
      when 'is'
        if value.is_a?(Array)
          vals = value.map { |v| Integer(v) }.join(', ')
          "#{prefix}#{field} IN (#{vals})"
        else
          "#{prefix}#{field} = #{Integer(value)}"
        end
      when 'is_not'
        if value.is_a?(Array)
          vals = value.map { |v| Integer(v) }.join(', ')
          "#{prefix}#{field} NOT IN (#{vals})"
        else
          "#{prefix}#{field} != #{Integer(value)}"
        end
      end
    rescue ArgumentError
      nil
    end

    def build_string_filter_clause(prefix, field, operator, value)
      case operator
      when 'is'
        if value.is_a?(Array)
          vals = value.map { |v| "'#{sanitize_string(v)}'" }.join(', ')
          "#{prefix}#{field} IN (#{vals})"
        else
          "#{prefix}#{field} = '#{sanitize_string(value)}'"
        end
      when 'is_not'
        if value.is_a?(Array)
          vals = value.map { |v| "'#{sanitize_string(v)}'" }.join(', ')
          "#{prefix}#{field} NOT IN (#{vals})"
        else
          "#{prefix}#{field} != '#{sanitize_string(value)}'"
        end
      when 'contains'
        "lower(#{prefix}#{field}) LIKE '%#{sanitize_like(value.to_s.downcase)}%'"
      end
    end

    # Resolve integer ID fields (link_id, campaign_id) to {id, name} pairs.
    # Strategy:
    #   - With search (q): PG name search first → verify IDs exist in CH
    #   - Without search:  CH IDs first → PG name lookup
    # Cursor pagination via last-seen ID.
    # `ch_table` and `ch_final` control which CH table to query.
    def resolve_id_field(pid, col, q: nil, limit: 20, date_clause: '',
                         cursor: nil, ch_table: 'session_summary', ch_final: true)
      raise ArgumentError, "Invalid CH table: #{ch_table}" unless ALLOWED_CH_TABLES.include?(ch_table)
      raise ArgumentError, "Invalid CH column: #{col}" unless RESOLVABLE_ID_COLUMNS.include?(col)

      pid = Integer(pid) # defensive: pid/col are interpolated into SQL below, never placeholdered
      fetch_limit = limit + 1
      final_kw = ch_final ? 'FINAL' : ''
      model = col == 'campaign_id' ? Campaign : Link

      if q.present?
        scope = model.where(id: ch_id_set(pid, col, date_clause, ch_table: ch_table, ch_final: ch_final))
                     .where('LOWER(name) LIKE ?', "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%")
                     .order(:id)
        scope = scope.where('id > ?', cursor.to_i) if cursor.present?
        records = scope.limit(fetch_limit).pluck(:id, :name)
      else
        cursor_int = cursor.present? ? (Integer(cursor) rescue nil) : nil
        cursor_clause = cursor_int ? "AND #{col} > #{cursor_int}" : ''
        rows = with_guard(<<~SQL).to_a
          SELECT DISTINCT #{col} AS id
          FROM #{ch_table} #{final_kw}
          WHERE project_id = #{pid} AND #{col} > 0
          #{date_clause}
          #{cursor_clause}
          ORDER BY id
          LIMIT #{fetch_limit}
        SQL
        ids = rows.map { |r| r['id'].to_i }
        return { values: [], next_cursor: nil } if ids.empty?

        name_map = model.where(id: ids).pluck(:id, :name).to_h
        records = ids.map { |id| [id, name_map[id] || id.to_s] }
      end

      has_more = records.size > limit
      records = records.first(limit)
      next_cursor = has_more ? records.last[0] : nil

      { values: records.map { |id, name| { id: id, name: name } }, next_cursor: next_cursor }
    end

    # Resolve visitor_id as raw integers (matching what the events table shows).
    # Search (q) does exact integer match. Cursor is integer-based.
    def resolve_visitor_field(pid, q: nil, limit: 20, date_clause: '',
                              cursor: nil, ch_table: 'session_summary', ch_final: true)
      raise ArgumentError, "Invalid CH table: #{ch_table}" unless ALLOWED_CH_TABLES.include?(ch_table)

      pid = Integer(pid) # defensive: pid is interpolated into SQL below, never placeholdered
      fetch_limit = limit + 1
      final_kw = ch_final ? 'FINAL' : ''

      if q.present?
        vid = Integer(q) rescue nil
        return { values: [], next_cursor: nil } unless vid

        rows = with_guard(<<~SQL).to_a
          SELECT DISTINCT visitor_id AS id
          FROM #{ch_table} #{final_kw}
          WHERE project_id = #{pid} AND visitor_id = #{vid}
          #{date_clause}
          LIMIT 1
        SQL
        ids = rows.map { |r| r['id'].to_i }
        return { values: ids.map { |id| { id: id, name: id.to_s } }, next_cursor: nil }
      end

      cursor_int = cursor.present? ? (Integer(cursor) rescue nil) : nil
      cursor_clause = cursor_int ? "AND visitor_id > #{cursor_int}" : ''
      rows = with_guard(<<~SQL).to_a
        SELECT DISTINCT visitor_id AS id
        FROM #{ch_table} #{final_kw}
        WHERE project_id = #{pid} AND visitor_id > 0
        #{date_clause}
        #{cursor_clause}
        ORDER BY id
        LIMIT #{fetch_limit}
      SQL

      ids = rows.map { |r| r['id'].to_i }
      return { values: [], next_cursor: nil } if ids.empty?

      has_more = ids.size > limit
      ids = ids.first(limit)
      next_cursor = has_more ? ids.last : nil

      { values: ids.map { |id| { id: id, name: id.to_s } }, next_cursor: next_cursor }
    end

    def ch_id_set(pid, col, date_clause, ch_table: 'session_summary', ch_final: true)
      raise ArgumentError, "Invalid CH table: #{ch_table}" unless ALLOWED_CH_TABLES.include?(ch_table)
      raise ArgumentError, "Invalid CH column: #{col}" unless RESOLVABLE_ID_COLUMNS.include?(col)

      pid = Integer(pid) # defensive: pid/col are interpolated into SQL below, never placeholdered
      final_kw = ch_final ? 'FINAL' : ''
      with_guard(<<~SQL).to_a.map { |r| r['id'].to_i }
        SELECT DISTINCT #{col} AS id
        FROM #{ch_table} #{final_kw}
        WHERE project_id = #{pid} AND #{col} > 0
        #{date_clause}
      SQL
    end

    # Under primary there is no Postgres left to fall back to, so a swallowed failure would
    # render a zeroed dashboard with 200 OK. Raise past every caller's rescue instead.
    def log_query_failure(method, error)
      raise error if PROPAGATED_ERRORS.any? { |klass| error.is_a?(klass) }

      msg = error.message.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      Rails.logger.error("#{name}##{method}: query failed — #{error.class}: #{msg}")
      Clickhouse.unavailable!("#{name}##{method}", error)
    end

    # Both delegate to Analytics::SourceTaxonomy — the single source of truth so
    # classification (expr) and per-bucket filtering (where_clause) stay consistent.
    def source_type_expr(table_alias = nil)
      Analytics::SourceTaxonomy.expr(table_alias)
    end

    def source_where_clause(source, table_alias = nil)
      Analytics::SourceTaxonomy.where_clause(source, table_alias)
    end
  end
end
