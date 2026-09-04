# frozen_string_literal: true

# Schema validation helper for Analytics endpoints.
# Every analytics response is validated against these schemas so that
# additions, removals, or type changes in the API surface are caught
# automatically by the test suite.
#
# Usage:
#   include AnalyticsSchemaHelper
#   assert_analytics_schema :events_index
#   assert_analytics_schema :events_index, parsed_json
#   assert_each_analytics_item :event_item, json["data"]
module AnalyticsSchemaHelper
  # ---------------------------------------------------------------------------
  # Type DSL (same as McpSchemaHelper)
  # ---------------------------------------------------------------------------
  #   :string           non-nil, non-blank String
  #   :string?          String or nil
  #   :integer          non-nil Integer
  #   :integer?         Integer or nil
  #   :float            non-nil Float/Integer (Numeric)
  #   :float?           Float/Integer or nil
  #   :numeric          non-nil Numeric
  #   :numeric?         Numeric or nil
  #   :boolean          true | false
  #   :boolean?         true | false | nil
  #   :array            Array (inner items validated separately)
  #   :hash             non-nil Hash
  #   :hash?            Hash or nil
  #   :integer_values   Hash where all values are Integer (dynamic keys)
  #   :float_values?    Hash where all values are Float/nil (dynamic keys)
  #   :any              non-nil value
  #   [:string]         Array of Strings
  #   { "k" => :type }  nested Hash validated recursively
  # ---------------------------------------------------------------------------

  # =========================================================================
  # Output Schemas — one per distinct response shape
  # =========================================================================
  OUTPUT_SCHEMAS = {
    # ── Events Explorer ────────────────────────────────────────────────

    # GET /events (index)
    events_index: {
      "data" => :array,
      "next_cursor" => :string?,
      "total_count" => :integer?
    },

    # Each item inside events_index["data"]
    event_item: {
      "event_id" => :string?,
      "project_id" => :integer,
      "event_type" => :string,
      "event_name" => :string?,
      "screen_name" => :string?,
      "visitor_id" => :integer,
      "device_id" => :integer?,
      "link_id" => :integer?,
      "campaign_id" => :integer?,
      "session_id" => :string?,
      "platform" => :string?,
      "app_version" => :string?,
      "device_model" => :string?,
      "os" => :string?,
      "os_version" => :string?,
      "country" => :string?,
      "city" => :string?,
      "tracking_source" => :string?,
      "tracking_medium" => :string?,
      "tracking_campaign" => :string?,
      "ads_platform" => :string?,
      "sdk_identifier" => :string?,
      "engagement_time" => :integer?,
      "visitor_uuid" => :string?,
      "resolved_visitor_id" => :integer?,
      "properties" => :hash?,
      "created_at" => :string
    },

    # GET /events/:event_id (show)
    event_show: {
      "data" => :hash
    },

    # GET /events/volume
    events_volume: {
      "buckets" => :array
    },

    # Each item inside events_volume["buckets"]
    volume_bucket: {
      "bucket" => :string,
      "count" => :integer
    },

    # GET /events/field-values
    events_field_values: {
      "values" => [:string],
      "next_cursor" => :string?
    },

    # GET /events/fields
    events_fields: {
      "fields" => :array
    },

    # Each item inside events_fields["fields"]
    field_item: {
      "name" => :string,
      "type" => :string
    },

    # ── Overview ───────────────────────────────────────────────────────

    # GET /overview/key-metrics
    overview_key_metrics: {
      "metrics" => {
        "views" => :integer,
        "link_views" => :integer,
        "opens" => :integer,
        "installs" => :integer,
        "link_driven_installs" => :integer,
        "organic_installs" => :integer,
        "reinstalls" => :integer,
        "app_opens" => :integer,
        "referred_users" => :integer,
        "total_users" => :integer,
        "new_users" => :integer,
        "returning_users" => :integer,
        "returning_rate" => :float,
        "revenue" => :integer,
        "units_sold" => :integer,
        "cancellations" => :integer,
        "first_time_purchases" => :integer,
        "arpu" => :float,
        "arppu" => :float
      }
    },

    # GET /overview/key-metrics/series
    overview_key_metric_series: {
      "metric" => :string,
      "points" => :array
    },

    # Each item inside overview_key_metric_series["points"]
    series_point: {
      "date" => :string,
      "value" => :integer
    },

    # GET /overview/versions
    overview_versions: {
      "platforms" => :hash
    },

    # Each item in a platforms array
    version_users_item: {
      "version" => :string,
      "users" => :integer,
      "percent" => :float
    },

    # GET /overview/trends/users
    user_trends: {
      "points" => :array
    },

    # Each trend point
    trend_point: {
      "date" => :string,
      "new_users" => :integer,
      "previous_new_users" => :integer,
      "users" => :integer,
      "previous_users" => :integer,
      "revenue_usd_cents" => :integer,
      "previous_revenue_usd_cents" => :integer
    },

    # GET /overview/sources/breakdown
    sources_breakdown: {
      "sources" => :array,
      "total" => :integer
    },

    # Each source item
    source_item: {
      "name" => :string,
      "value" => :integer
    },

    # GET /overview/versions/distribution
    version_distribution: {
      "entries" => :array
    },

    # Each distribution entry
    distribution_item: {
      "version" => :string,
      "release_date" => :string?,
      "platforms" => :hash,
      "total" => :integer
    },

    # ── Sessions ───────────────────────────────────────────────────────

    # GET /sessions (index)
    sessions_index: {
      "data" => :array,
      "next_cursor" => :string?
    },

    # Each item inside sessions_index["data"] — matches SessionsQueryService
    # LIST_COLUMNS + derived `source` + injected opaque `id`.
    # Used for BOTH a list row and the detail `session` object. `id` is injected
    # only on list rows (optional here so the detail object validates too).
    session_summary_item: {
      "session_id" => :string,
      "visitor_id" => :integer,
      "event_date" => :string,
      "started_at" => :string,
      "ended_at" => :string?,
      "duration_ms" => :integer,
      "event_count" => :integer,
      "platform" => :string?,
      "app_version" => :string?,
      "country" => :string?,
      "device_model" => :string?,
      "link_id" => :integer?,
      "campaign_id" => :integer?,
      "tracking_source" => :string?,
      "has_conversion" => :integer,
      "revenue_usd_cents" => :integer,
      "source" => :string?,
      "id" => :string?
    },

    # GET /sessions/:session_key (show)
    sessions_show: {
      "session" => :hash,
      "events" => :array
    },

    # Each event inside sessions_show["events"]
    session_event_item: {
      "event_id" => :string?,
      "event_type" => :string,
      "event_name" => :string?,
      "screen_name" => :string?,
      "created_at" => :string,
      "platform" => :string?,
      "app_version" => :string?,
      "country" => :string?,
      "link_id" => :integer?,
      "campaign_id" => :integer?,
      "engagement_time" => :integer?
    },

    # ── Retention ──────────────────────────────────────────────────────

    # GET /retention/summary
    retention_summary: {
      "day_1" => :float?,
      "day_7" => :float?,
      "day_30" => :float?,
      "sparkline" => :array,
      "median_churn_day" => :integer?
    },

    # Each sparkline point
    sparkline_point: {
      "date" => :string,
      "rate" => :float?
    },

    # ── Error responses ────────────────────────────────────────────────

    error_response: {
      "error" => :string
    },

    # Error envelope carrying a machine-readable code (e.g. over-cap 422 and
    # QueryTooHeavy → 422). Strict: EXACTLY { error, error_code }, no extra keys.
    error_with_code: {
      "error" => :string,
      "error_code" => :string
    }
  }.freeze

  # =========================================================================
  # Input Schemas — required/optional params + enum constraints per endpoint
  # =========================================================================
  INPUT_SCHEMAS = {
    # ── Events Explorer ──────────────────────────────────────────────
    events_index: {
      required: [],
      optional: %w[start_date end_date cursor limit sort_by sort_order search filters include_count],
      enums: {
        "sort_by" => %w[created_at event_type event_name platform],
        "sort_order" => %w[asc desc]
      },
      integers: %w[limit],
      integer_ranges: { "limit" => 1..200 },
      max_date_range_days: 90
    },

    events_show: {
      required: %w[event_id],
      optional: []
    },

    events_volume: {
      required: [],
      optional: %w[start_date end_date bucket search filters timezone],
      enums: {
        "bucket" => %w[hour day week month]
      },
      max_date_range_days: 90
    },

    events_field_values: {
      required: %w[field],
      optional: %w[q limit],
      enums: {
        "field" => Api::V1::Analytics::BaseController::ALLOWED_FIELD_VALUES_FIELDS
      },
      # Open extension to the field enum: "user.<key>" (sdk_attributes) is also accepted.
      enum_patterns: { "field" => /\Auser\.[^\x00-\x20\\`\x7f]+\z/ },
      integers: %w[limit],
      integer_ranges: { "limit" => 1..200 }
    },

    events_fields: {
      required: [],
      optional: []
    },

    # ── Overview ─────────────────────────────────────────────────────
    overview_key_metrics: {
      required: [],
      optional: %w[start_date end_date platform],
      enums: { "platform" => %w[ios android desktop web] }
    },

    overview_key_metric_series: {
      required: %w[metric],
      optional: %w[start_date end_date platform],
      enums: {
        "metric" => %w[views link_views opens installs link_driven_installs organic_installs reinstalls app_opens referred_users],
        "platform" => %w[ios android desktop web]
      }
    },

    overview_versions: {
      required: [],
      optional: %w[start_date end_date platform],
      enums: { "platform" => %w[ios android desktop web] }
    },

    overview_version_distribution: {
      required: [],
      optional: %w[start_date end_date platform limit],
      enums: { "platform" => %w[ios android desktop web] },
      integers: %w[limit],
      integer_ranges: { "limit" => 1..100 }
    },

    overview_user_trends: {
      required: [],
      optional: %w[start_date end_date platform],
      enums: { "platform" => %w[ios android desktop web] }
    },

    overview_sources_breakdown: {
      required: [],
      optional: %w[start_date end_date platform],
      enums: { "platform" => %w[ios android desktop web] }
    },

    # ── Sessions ─────────────────────────────────────────────────────
    sessions_index: {
      required: [],
      optional: %w[start_date end_date cursor limit filters source],
      enums: {
        "source" => %w[campaigns referrals api_links links organic]
      },
      integers: %w[limit],
      integer_ranges: { "limit" => 1..200 }
    },

    sessions_show: {
      required: %w[session_key],
      optional: []
    },

    # ── Retention ────────────────────────────────────────────────────
    retention_summary: {
      required: [],
      optional: %w[granularity platform start_date end_date filters],
      enums: {
        "granularity" => %w[weekly monthly],
        "platform" => %w[ios android desktop web]
      }
    }
  }.freeze

  # =========================================================================
  # Assertion Methods
  # =========================================================================

  # Validate JSON body matches the named output schema. Fails on missing keys,
  # wrong types, and (in strict mode) unexpected keys.
  def assert_analytics_schema(schema_name, json = nil, strict: true)
    json ||= JSON.parse(response.body)
    schema = OUTPUT_SCHEMAS.fetch(schema_name) { flunk "Unknown analytics schema: #{schema_name}" }
    validate_analytics_object(json, schema, path: schema_name.to_s, strict: strict)
    json
  end

  # Validate every item in an array against a schema.
  def assert_each_analytics_item(schema_name, items)
    schema = OUTPUT_SCHEMAS.fetch(schema_name) { flunk "Unknown analytics schema: #{schema_name}" }
    assert_kind_of Array, items, "expected Array for #{schema_name} items"
    items.each_with_index do |item, i|
      validate_analytics_object(item, schema, path: "#{schema_name}[#{i}]", strict: true)
    end
  end

  private

  def validate_analytics_object(obj, schema, path:, strict: true)
    assert_kind_of Hash, obj, "#{path}: expected Hash, got #{obj.class} (#{obj.inspect[0..100]})"

    schema.each do |key, type_spec|
      optional = analytics_nullable_type?(type_spec)
      unless optional || obj.key?(key)
        flunk "#{path}: missing required key '#{key}'. Present keys: #{obj.keys.sort}"
      end
      validate_analytics_value(obj[key], type_spec, path: "#{path}.#{key}") if obj.key?(key)
    end

    if strict
      extra = obj.keys - schema.keys
      if extra.any?
        flunk "#{path}: unexpected keys #{extra.inspect} — response schema may have changed. " \
              "Update AnalyticsSchemaHelper::OUTPUT_SCHEMAS[:#{path.split('.').first}] if this is intentional."
      end
    end
  end

  def validate_analytics_value(value, type_spec, path:) # rubocop:disable Metrics/CyclomaticComplexity
    case type_spec
    when :string
      assert_not_nil value, "#{path}: expected String, got nil"
      assert_kind_of String, value, "#{path}: expected String, got #{value.class}"
      assert value.present?, "#{path}: expected non-blank String"
    when :string?
      assert(value.nil? || value.is_a?(String), "#{path}: expected String or nil, got #{value.class}")
    when :integer
      assert_not_nil value, "#{path}: expected Integer, got nil"
      assert_kind_of Integer, value, "#{path}: expected Integer, got #{value.class}"
    when :integer?
      assert(value.nil? || value.is_a?(Integer), "#{path}: expected Integer or nil, got #{value.class}")
    when :float
      assert_not_nil value, "#{path}: expected Numeric, got nil"
      assert_kind_of Numeric, value, "#{path}: expected Numeric (Float/Integer), got #{value.class}"
    when :float?
      assert(value.nil? || value.is_a?(Numeric), "#{path}: expected Numeric or nil, got #{value.class}")
    when :numeric
      assert_not_nil value, "#{path}: expected Numeric, got nil"
      assert_kind_of Numeric, value, "#{path}: expected Numeric, got #{value.class}"
    when :numeric?
      assert(value.nil? || value.is_a?(Numeric), "#{path}: expected Numeric or nil, got #{value.class}")
    when :boolean
      assert [true, false].include?(value), "#{path}: expected boolean, got #{value.inspect}"
    when :boolean?
      assert [true, false, nil].include?(value), "#{path}: expected boolean or nil, got #{value.inspect}"
    when :array
      assert_kind_of Array, value, "#{path}: expected Array, got #{value.class}"
    when :hash
      assert_not_nil value, "#{path}: expected Hash, got nil"
      assert_kind_of Hash, value, "#{path}: expected Hash, got #{value.class}"
    when :hash?
      assert(value.nil? || value.is_a?(Hash), "#{path}: expected Hash or nil, got #{value.class}")
    when :integer_values
      assert_not_nil value, "#{path}: expected Hash with Integer values, got nil"
      assert_kind_of Hash, value, "#{path}: expected Hash, got #{value.class}"
      value.each do |k, v|
        assert_kind_of Integer, v, "#{path}[#{k}]: expected Integer, got #{v.class} (#{v.inspect})"
      end
    when :float_values?
      assert_not_nil value, "#{path}: expected Hash with Numeric/nil values, got nil"
      assert_kind_of Hash, value, "#{path}: expected Hash, got #{value.class}"
      value.each do |k, v|
        assert(v.nil? || v.is_a?(Numeric), "#{path}[#{k}]: expected Numeric or nil, got #{v.class} (#{v.inspect})")
      end
    when :any
      assert_not_nil value, "#{path}: expected non-nil value"
    when Array
      assert_kind_of Array, value, "#{path}: expected Array, got #{value.class}"
      inner = type_spec.first
      value.each_with_index do |item, i|
        validate_analytics_value(item, inner, path: "#{path}[#{i}]")
      end
    when Hash
      validate_analytics_object(value, type_spec, path: path, strict: true)
    else
      flunk "#{path}: unknown type_spec #{type_spec.inspect}"
    end
  end

  def analytics_nullable_type?(spec)
    return true if spec.is_a?(Symbol) && spec.to_s.end_with?("?")
    false
  end
end
