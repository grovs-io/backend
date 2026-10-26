# frozen_string_literal: true

module Analytics
  # The explorer's FROM: `events` unioned with purchases shaped as events. Pure string building.
  module EventsSource
    SOURCE_KEY = 'events_with_purchases'
    LC_EMPTY = "CAST('', 'LowCardinality(String)')"
    LC_ARRAY = "CAST([], 'Array(LowCardinality(String))')"

    # Every `events` column in DDL order; the second element is the purchase branch's typed default.
    COLUMN_DEFAULTS = [
      ['event_id', nil], ['project_id', nil], ['event_type', nil], ['event_name', nil],
      ['screen_name', "''"], ['device_id', nil], ['visitor_id', nil], ['link_id', nil],
      ['inviter_id', '0'], ['campaign_id', '0'], ['platform', nil], ['app_version', "''"],
      ['build', "''"], ['vendor_id', "''"], ['device_model', "''"], ['os', LC_EMPTY],
      ['os_version', "''"], ['timezone', "''"], ['language', LC_EMPTY], ['country', LC_EMPTY],
      ['city', "''"], ['tracking_source', LC_EMPTY], ['tracking_medium', LC_EMPTY],
      ['tracking_campaign', "''"], ['ads_platform', LC_EMPTY],
      ['link_tags', LC_ARRAY], ['sdk_identifier', "''"],
      ['sdk_attributes', "CAST('{}', 'JSON')"], ['session_id', nil], ['engagement_time', '0'],
      ['properties', nil], ['tags', LC_ARRAY],
      ['sdk_generated', '0'], ['link_visitor_id', '0'], ['ip', "''"], ['remote_ip', "''"],
      ['path', "''"], ['created_at', nil], ['ingested_at', nil]
    ].freeze
    COLUMNS = COLUMN_DEFAULTS.map(&:first).freeze

    # All values are strings: explorer property filters cast to String anyway, and map() needs one type.
    PURCHASE_PROPERTY_KEYS = %w[
      product_id purchase_type store_source transaction_id original_transaction_id
      quantity currency usd_price_cents purchase_date
    ].freeze

    PURCHASE_PROPERTIES_SQL = "CAST(toJSONString(map('purchase', map(" \
                              "#{PURCHASE_PROPERTY_KEYS.map { |k| "'#{k}', toString(p.#{k})" }.join(', ')}" \
                              "))), 'JSON')".freeze

    # Rows written before the platform column existed fall back to the store mapping.
    PURCHASE_PLATFORM_SQL = "CAST(if(p.platform != '', p.platform, " \
                            "multiIf(p.store_source = 'apple', 'ios', p.store_source = 'google', 'android', '')), " \
                            "'LowCardinality(String)')"

    # campaign_id stays 0 by decision: purchase_events carries link_id but no campaign snapshot.
    PURCHASE_EXPRS = {
      'event_id' => "lower(hex(MD5(concat('purchase:', p.transaction_id, ':', p.event_type))))",
      'project_id' => 'p.project_id',
      'event_type' => "CAST('purchase', 'LowCardinality(String)')",
      'event_name' => "CAST(p.event_type, 'String')",
      'device_id' => 'p.device_id',
      'visitor_id' => 'p.visitor_id',
      'link_id' => 'p.link_id',
      'platform' => PURCHASE_PLATFORM_SQL,
      'session_id' => 'p.session_id',
      'properties' => PURCHASE_PROPERTIES_SQL,
      'created_at' => "if(p.recorded_at = toDateTime64(0, 3, 'UTC'), p.created_at, p.recorded_at)",
      'ingested_at' => 'p.created_at'
    }.freeze

    PURCHASE_SELECT = COLUMN_DEFAULTS.map { |col, default| "#{PURCHASE_EXPRS.fetch(col, default)} AS #{col}" }
                                     .join(', ').freeze

    # Opaque 32-hex id (store transaction ids carry dots, which the :event_id route rejects).
    def self.purchase_event_id(transaction_id, event_type)
      Digest::MD5.hexdigest("purchase:#{transaction_id}:#{event_type}")
    end

    # start_sql is a pre-formatted CH time; purchases dedup with LIMIT BY since FINAL kills pruning.
    def self.sql(final:, project_id:, start_sql: nil)
      "(SELECT #{COLUMNS.join(', ')} FROM events#{final ? ' FINAL' : ''} " \
        "UNION ALL SELECT * FROM #{purchase_sql(project_id: project_id, start_sql: start_sql)})"
    end

    # Purchases shaped as events, one row per purchase; event_id is an already-sanitized hex id.
    def self.purchase_sql(project_id:, start_sql: nil, event_id: nil)
      # LIMIT BY blocks outer pushdown and runs after WHERE: filters go here, true for every version.
      where = ["p.project_id = #{Integer(project_id)}", 'p.visitor_id > 0']
      where << "p.created_at >= toDateTime64('#{start_sql}', 3, 'UTC')" if start_sql
      where << "#{PURCHASE_EXPRS['event_id']} = '#{event_id}'" if event_id
      "(SELECT #{PURCHASE_SELECT} FROM purchase_events AS p WHERE #{where.join(' AND ')} " \
        'ORDER BY p.created_at DESC LIMIT 1 BY p.project_id, p.transaction_id, p.event_type)'
    end

    def self.purchase_field?(field)
      field = field.to_s
      field.start_with?('purchase.') && PURCHASE_PROPERTY_KEYS.include?(field.delete_prefix('purchase.'))
    end
  end
end
