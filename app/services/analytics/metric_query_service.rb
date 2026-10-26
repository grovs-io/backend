# frozen_string_literal: true

module Analytics
  # Runs a MetricQuery in one ClickHouse round trip and shapes rows, other, total and points.
  module MetricQueryService
    extend QueryHelpers

    TOTAL_KEY = '__total__'

    def self.run(project_id, query)
      pid = Integer(project_id)
      Rails.cache.fetch("analytics:metric_query:v3:#{pid}:#{query.cache_key}", expires_in: DashboardCacheTtl.value) do
        compute(pid, query)
      end
    rescue StandardError => e
      log_query_failure(:run, e)
      { metric: query.metric, group_by: query.group_by, rows: [], other: nil, total: { value: 0 } }
    end

    def self.compute(pid, query)
      plan = query.plan(pid)
      rows = with_guard(main_sql(query, plan)).to_a
      buckets = bucketize(query, rows)
      previous = query.compare ? previous_totals(query, query.plan(pid, previous: true), buckets.keys) : nil
      shape(query, buckets, previous, rows)
    end
    private_class_method :compute

    def self.bucket_expr(query, plan)
      return "'#{MetricQuery::ALL_KEY}'" if query.group_by.nil?

      top = "SELECT #{plan[:dim]} FROM #{plan[:from]} WHERE #{plan[:where]} GROUP BY #{plan[:dim]} " \
            "ORDER BY #{plan[:agg]} DESC, #{plan[:dim]} LIMIT #{query.limit}"
      "if(#{plan[:dim]} IN (#{top}), #{plan[:dim]}, '#{MetricQuery::OTHER_KEY}')"
    end
    private_class_method :bucket_expr

    # Counters sum in Ruby; uniques need a per-bucket and a grand-total branch to stay exact.
    def self.main_sql(query, plan)
      bucket = bucket_expr(query, plan)
      uniq = MetricQuery::UNIQUES.key?(query.metric)
      branches = []
      if query.granularity
        branches << "SELECT #{bucket} AS bucket, #{query.window_sql(plan[:date_expr])} AS w, #{plan[:agg]} AS v " \
                    "FROM #{plan[:from]} WHERE #{plan[:where]} GROUP BY bucket, w"
      end
      if query.granularity.nil? || uniq
        branches << "SELECT #{bucket} AS bucket, -1 AS w, #{plan[:agg]} AS v FROM #{plan[:from]} WHERE #{plan[:where]} GROUP BY bucket"
      end
      branches << "SELECT '#{TOTAL_KEY}' AS bucket, -1 AS w, #{plan[:agg]} AS v FROM #{plan[:from]} WHERE #{plan[:where]}" if uniq
      branches.join("\nUNION ALL\n")
    end
    private_class_method :main_sql

    # { key => { total:, points: [Integer]|nil } }
    def self.bucketize(query, rows)
      windows = query.granularity ? query.windows : nil
      out = Hash.new { |h, k| h[k] = { total: 0, points: windows && Array.new(windows.size, 0) } }
      rows.each do |r|
        key = r['bucket'].to_s
        next if key == TOTAL_KEY

        w = r['w'].to_i
        v = r['v'].to_i
        if w.negative?
          out[key][:total] = v
        elsif windows && w < windows.size
          out[key][:points][w] = v
        end
      end
      if windows && !MetricQuery::UNIQUES.key?(query.metric)
        out.each_value { |b| b[:total] = b[:points].sum }
      end
      out
    end
    private_class_method :bucketize

    def self.previous_totals(query, plan, keys)
      known = keys.reject { |k| k == MetricQuery::OTHER_KEY }
      bucket = if query.group_by.nil?
                 "'#{MetricQuery::ALL_KEY}'"
               else
                 list = known.map { |k| "'#{sanitize_string(k)}'" }.join(', ')
                 known.empty? ? "'#{MetricQuery::OTHER_KEY}'" : "if(#{plan[:dim]} IN (#{list}), #{plan[:dim]}, '#{MetricQuery::OTHER_KEY}')"
               end
      sql = "SELECT #{bucket} AS bucket, #{plan[:agg]} AS v FROM #{plan[:from]} WHERE #{plan[:where]} GROUP BY bucket"
      sql += "\nUNION ALL\nSELECT '#{TOTAL_KEY}' AS bucket, #{plan[:agg]} AS v FROM #{plan[:from]} WHERE #{plan[:where]}" if MetricQuery::UNIQUES.key?(query.metric)
      with_guard(sql).to_a.to_h { |r| [r['bucket'].to_s, r['v'].to_i] }
    end
    private_class_method :previous_totals

    def self.shape(query, buckets, previous, rows)
      windows = query.granularity ? query.windows : nil
      # A key can leave the top-N, so there may be a previous 'other' bucket but no current one.
      other = buckets.delete(MetricQuery::OTHER_KEY) ||
              (previous&.key?(MetricQuery::OTHER_KEY) ? { total: 0, points: windows && Array.new(windows.size, 0) } : nil)
      labels = labels_for(query, buckets.keys)
      to_row = lambda do |key, b, label|
        row = { key: key, label: label, value: b[:total] }
        row[:previous] = previous ? previous.fetch(key, 0) : nil
        row[:points] = windows ? windows.each_with_index.map { |(from, _), i| { date: from.to_s, value: b[:points][i] } } : nil
        row
      end
      shaped = buckets.map { |k, b| to_row.call(k, b, labels[k]) }.sort_by { |r| [-r[:value], r[:key]] }
      total = total_for(query, shaped, other, rows, previous)
      result = { metric: query.metric, group_by: query.group_by, rows: shaped,
                 other: other && to_row.call(MetricQuery::OTHER_KEY, other, 'Other'), total: total }
      # The previous window clamps to the retention cutoff, so callers must see what it actually covered.
      result[:previous_range] = { start: query.prev_start_day, end: query.prev_end_day } if query.compare
      result
    end
    private_class_method :shape

    def self.total_for(query, shaped, other, rows, previous)
      if MetricQuery::UNIQUES.key?(query.metric)
        value = rows.find { |r| r['bucket'].to_s == TOTAL_KEY }&.dig('v').to_i
        prev = previous&.fetch(TOTAL_KEY, 0)
      else
        value = shaped.sum { |r| r[:value] } + (other ? other[:total] : 0)
        # Every previous row is bucketed into a current key, other or 'all', so the sum is the whole period.
        prev = previous&.values&.sum
      end
      { value: value, previous: prev }
    end
    private_class_method :total_for

    def self.labels_for(query, keys)
      base = keys.to_h do |k|
        none = k.empty? || (MetricQuery::ID_DIMENSIONS.include?(query.group_by) && k == '0')
        [k, none ? '(none)' : k]
      end
      case query.group_by
      when 'link_id' then base.merge(Link.where(id: keys.map(&:to_i)).pluck(:id, :name).to_h { |id, n| [id.to_s, n.presence || id.to_s] })
      when 'campaign_id' then base.merge(Campaign.where(id: keys.map(&:to_i)).pluck(:id, :name).to_h { |id, n| [id.to_s, n.presence || id.to_s] })
      when 'source' then base.merge(keys.index_with { |k| display_source_name(k) })
      when nil then { MetricQuery::ALL_KEY => 'All' }
      else base
      end
    end
    private_class_method :labels_for
  end
end
