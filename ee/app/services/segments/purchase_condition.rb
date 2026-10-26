module Segments
  class PurchaseCondition
    LOOKBACK_DAYS = Integer(ENV.fetch("SEGMENT_PURCHASE_LOOKBACK_DAYS", 365))
    LIST_FIELDS = %w[product_id purchase_type store_source].freeze
    # Google files a refund as "<buy txn>_refund"; qualified so select aliases cannot shadow columns.
    TRANSACTION_SQL = "if(purchase_events.event_type = #{Quoting.literal(Grovs::Purchases::EVENT_REFUND)} " \
                      "AND purchase_events.store_source = #{Quoting.literal(Grovs::Webhooks::GOOGLE)} " \
                      "AND endsWith(purchase_events.transaction_id, '_refund'), " \
                      "substring(purchase_events.transaction_id, 1, length(purchase_events.transaction_id) - 7), " \
                      "purchase_events.transaction_id)".freeze

    def self.build(raw, path:, errors:, cutoff_date:)
      before = errors.size
      attrs = {}
      LIST_FIELDS.each do |field|
        next unless raw.key?(field)

        attrs[field] = Quoting.clean_values(raw[field], path: "#{path}.#{field}", errors: errors)
      end
      if attrs["purchase_type"] && (attrs["purchase_type"] - Grovs::Purchases::TYPES).any?
        errors << { path: "#{path}.purchase_type", message: "purchase_type must be one of #{Grovs::Purchases::TYPES.join(', ')}" }
      end
      attrs["count"] = raw.key?("count") ? Quoting.strict_int(raw["count"]) : 1
      errors << { path: "#{path}.count", message: "count must be an integer >= 1" } unless attrs["count"]&.positive?
      attrs["min_total_usd_cents"] = raw.key?("min_total_usd_cents") ? Quoting.strict_int(raw["min_total_usd_cents"]) : 0
      unless attrs["min_total_usd_cents"] && attrs["min_total_usd_cents"] >= 0
        errors << { path: "#{path}.min_total_usd_cents", message: "min_total_usd_cents must be an integer >= 0" }
      end
      attrs["window"] = Window.normalize(raw["window"], cap_days: LOOKBACK_DAYS, cutoff_date: cutoff_date, path: "#{path}.window", errors: errors)
      attrs["negate"] = Quoting.strict_flag(raw, "negate", path, errors)
      return nil if errors.size > before

      new(attrs)
    end

    def initialize(attrs) = @attrs = attrs

    def to_h = { "type" => "purchase" }.merge(@attrs)
    def negative? = @attrs["negate"]
    def window = @attrs["window"]

    def rows_sql(env, idx)
      b = Window.bounds(window, cutoff_date: env.cutoff_date, now: env.now)
      buy = Quoting.literal(Grovs::Purchases::EVENT_BUY)
      where = ["buys > 0", "refunds <= reversals", "visitor_id != 0", Window.sql("bought_at", b)]
      LIST_FIELDS.each { |f| where << Quoting.string_clause(f, "is", @attrs[f]) if @attrs[f] }
      "SELECT visitor_id, toUInt8(#{idx}) AS ci, toUInt64(count()) AS n, toString(sum(cents)) AS s FROM (" \
        "SELECT anyIf(visitor_id, event_type = #{buy}) AS visitor_id, anyIf(purchase_date, event_type = #{buy}) AS bought_at, " \
        "anyIf(product_id, event_type = #{buy}) AS product_id, anyIf(purchase_type, event_type = #{buy}) AS purchase_type, " \
        "anyIf(store_source, event_type = #{buy}) AS store_source, " \
        "anyIf(toUInt64(greatest(usd_price_cents, 0)) * quantity, event_type = #{buy}) AS cents, " \
        "countIf(event_type = #{buy}) AS buys, countIf(event_type = #{Quoting.literal(Grovs::Purchases::EVENT_REFUND)}) AS refunds, " \
        "countIf(event_type = #{Quoting.literal(Grovs::Purchases::EVENT_REFUND_REVERSED)}) AS reversals " \
        "FROM purchase_events FINAL WHERE project_id = #{Integer(env.project_id)} AND #{history_from_sql(b)} GROUP BY #{TRANSACTION_SQL}" \
        ") WHERE #{where.join(' AND ')} GROUP BY visitor_id"
    end

    # Refunds are dated at or after their buy; the day absorbs client clock skew.
    def history_from_sql(bounds)
      from = "toDateTime64('#{(bounds.from - 1.day).utc.strftime(Window::FMT)}', 3, 'UTC')"
      "purchase_date >= #{from} AND created_at >= #{from}"
    end

    def predicate(idx)
      "sumIf(r.n, r.ci = #{idx}) >= #{Integer(@attrs['count'])} AND " \
        "sumIf(toUInt64OrZero(r.s), r.ci = #{idx}) >= #{Integer(@attrs['min_total_usd_cents'])}"
    end
  end
end
