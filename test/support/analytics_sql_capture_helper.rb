# frozen_string_literal: true

module AnalyticsSqlCaptureHelper
  CAPTURED_CH_METHODS = %i[select_all select_value execute].freeze

  def capture_ch_sql
    statements = []
    klass = Clickhouse.with { |conn| conn.class }
    originals = {}

    CAPTURED_CH_METHODS.each do |method_name|
      next unless klass.method_defined?(method_name)
      originals[method_name] = klass.instance_method(method_name)
      original = originals.fetch(method_name)
      klass.define_method(method_name) do |sql, *args, **kwargs, &block|
        statements << sql.to_s.squish
        original.bind(self).call(sql, *args, **kwargs, &block)
      end
    end

    yield
    statements
  ensure
    originals&.each do |method_name, original|
      klass.define_method(method_name, original)
    end
  end

  def explain_captured_selects(sqls)
    sqls.filter_map do |sql|
      next unless sql.match?(/\ASELECT|\AWITH/i)
      Clickhouse.with { |conn| conn.select_all("EXPLAIN indexes = 1 #{sql}") }
    end
  end
end
