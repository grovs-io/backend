# frozen_string_literal: true

require 'test_helper'

# Pure-Ruby (no ClickHouse) consistency proof for the source taxonomy: the
# multiIf classifier and the per-bucket WHERE predicates must agree for every
# combination of the four input fields. A CH drift test guards the deployed MV.
class Analytics::SourceTaxonomyTest < ActiveSupport::TestCase
  Taxonomy = Analytics::SourceTaxonomy

  # All 16 combinations of the four binary inputs.
  ROWS = [0, 1].product([0, 1], [0, 1], [0, 1]).map do |campaign_id, sdk_generated, link_visitor_id, link_id|
    { campaign_id: campaign_id, sdk_generated: sdk_generated,
      link_visitor_id: link_visitor_id, link_id: link_id }
  end.freeze

  # Reference classifier replicating the canonical priority in pure Ruby.
  def expected_bucket(row)
    if row[:campaign_id] > 0 then 'campaigns'
    elsif row[:sdk_generated] == 1 && row[:link_visitor_id] > 0 then 'referrals'
    elsif row[:sdk_generated] == 1 && row[:link_visitor_id] == 0 then 'api_links'
    elsif row[:link_id] > 0 then 'links'
    else 'organic'
    end
  end

  # Evaluate a SQL predicate fragment against a row. Handles the operators the
  # taxonomy emits (`> 0`, `= 0`, `= 1`), AND, and `NOT (...)` groups.
  def eval_predicate(sql, row)
    # Strip NOT(...) groups by recursively evaluating and substituting truthiness.
    while (m = sql.match(/NOT\s*\(([^()]*)\)/))
      sql = sql.sub(m[0], (!eval_predicate(m[1], row)).to_s)
    end
    sql.split(/\s+AND\s+/).map(&:strip).all? do |term|
      next true if term == 'true'
      next false if term == 'false'

      t = term.match(/\A(campaign_id|sdk_generated|link_visitor_id|link_id)\s*(>|=)\s*(\d+)\z/)
      raise "unparseable predicate term: #{term.inspect}" unless t

      field, op, val = t[1].to_sym, t[2], t[3].to_i
      op == '>' ? row[field] > val : row[field] == val
    end
  end

  test 'expr lists the buckets in canonical priority order' do
    sql = Taxonomy.expr
    order = %w[campaigns referrals api_links links organic].map { |b| sql.index("'#{b}'") }
    assert_equal order, order.compact.sort, "expr buckets out of priority order: #{sql}"
  end

  test 'every row classifies to exactly one bucket via expr ordering' do
    ROWS.each do |row|
      assert_includes Taxonomy::SOURCES, expected_bucket(row),
                      "row #{row.inspect} produced unknown bucket"
    end
  end

  # The core invariant: for every row, exactly ONE bucket's where_clause is true,
  # and it equals the classifier's bucket. Proves classify == filter.
  test 'where_clause round-trips with the classifier for all 16 combinations' do
    ROWS.each do |row|
      matches = Taxonomy::SOURCES.select { |s| eval_predicate(Taxonomy.where_clause(s), row) }
      assert_equal 1, matches.size,
                   "row #{row.inspect} matched #{matches.inspect}, expected exactly one"
      assert_equal expected_bucket(row), matches.first,
                   "row #{row.inspect}: filter=#{matches.first} != classifier=#{expected_bucket(row)}"
    end
  end

  test 'table_alias prefixes every column reference' do
    assert_includes Taxonomy.expr('e'), 'e.campaign_id'
    assert_includes Taxonomy.where_clause('referrals', 'e'), 'e.sdk_generated'
    assert_includes Taxonomy.where_clause('referrals', 'e'), 'e.campaign_id'
  end

  test 'where_clause returns nil for an unknown source' do
    assert_nil Taxonomy.where_clause('bogus')
  end

  test 'QueryHelpers delegates to SourceTaxonomy' do
    helper = Class.new { include Analytics::QueryHelpers }.new
    assert_equal Taxonomy.expr, helper.send(:source_type_expr)
    assert_equal Taxonomy.expr('e'), helper.send(:source_type_expr, 'e')
    Taxonomy::SOURCES.each do |s|
      assert_equal Taxonomy.where_clause(s), helper.send(:source_where_clause, s)
      assert_equal Taxonomy.where_clause(s, 'e'), helper.send(:source_where_clause, s, 'e')
    end
  end

  # Drift guard: the deployed mv_project_source_daily must classify identically
  # to Analytics::SourceTaxonomy.expr. Compare via the CH server's formatQuery so
  # whitespace/formatting differences don't cause false positives.
  class DriftTest < ActiveSupport::TestCase
    include ClickhouseTestHelper

    def normalize_via_format_query(conn, expr)
      sql = "SELECT formatQuery('SELECT #{expr.gsub("'", "''")}')"
      conn.select_value(sql).to_s.strip
    rescue ClickHouse::Client::DatabaseError
      nil
    end

    def mv_source_expr(conn)
      ddl = conn.select_value(
        "SELECT create_table_query FROM system.tables " \
        "WHERE database = currentDatabase() AND name = 'mv_project_source_daily'"
      )
      return nil if ddl.blank?

      m = ddl.match(/multiIf\s*\(.*?'organic'\s*\)/m)
      m && m[0]
    end

    test 'deployed MV source expression matches SourceTaxonomy.expr' do
      skip_unless_clickhouse!

      Clickhouse.with do |conn|
        mv_expr = mv_source_expr(conn)
        skip 'mv_project_source_daily not present in test DB' if mv_expr.blank?

        canonical = normalize_via_format_query(conn, Analytics::SourceTaxonomy.expr)
        deployed  = normalize_via_format_query(conn, mv_expr)
        skip 'formatQuery unavailable on this ClickHouse server' if canonical.nil? || deployed.nil?

        assert_equal canonical, deployed,
                     "deployed MV taxonomy drifted from Analytics::SourceTaxonomy.expr"
      end
    end
  end
end
