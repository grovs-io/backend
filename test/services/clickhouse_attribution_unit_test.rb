# frozen_string_literal: true

require "test_helper"

# CH-FREE unit tests: resolver/model control-flow and source-expression consistency.
# No ClickHouse instance required — these assert the SQL-building and guard logic.
class ClickhouseAttributionUnitTest < ActiveSupport::TestCase
  test "unknown model raises ArgumentError in source_breakdown" do
    Clickhouse.stub(:read_enabled?, true) do
      assert_raises(ArgumentError) do
        ClickhouseAttributionReadService.source_breakdown(1, start_date: "2026-06-01", end_date: "2026-06-30", model: :bogus)
      end
    end
  end

  test "reads return empty/nil when ClickHouse reads are disabled" do
    Clickhouse.stub(:read_enabled?, false) do
      assert_equal [], ClickhouseAttributionReadService.source_breakdown(1, start_date: "2026-06-01", end_date: "2026-06-30")
      assert_nil ClickhouseAttributionReadService.resolved_source_for(1, 2)
      assert_equal [], ClickhouseAttributionReadService.dimension_breakdown(1, start_date: "2026-06-01", end_date: "2026-06-30", dimension: :version)
    end
  end

  test "resolver expressions implement install-fallback and first-only semantics" do
    install = ClickhouseAttributionReadService::RESOLVED[:install]
    first = ClickhouseAttributionReadService::RESOLVED[:first]

    # install model: install_source, else first_touch_source, else organic.
    assert_includes install, "has_install"
    assert_includes install, "install_source"
    assert_includes install, "first_touch_source"
    assert_includes install, "'organic'"
    # first model: first_touch_source, else organic (no install branch).
    assert_includes first, "first_touch_source"
    assert_includes first, "'organic'"
    assert_not_includes first, "install_source"
  end

  test "memory guards cap memory and enable external group by" do
    guards = ClickhouseAttributionReadService::MEMORY_GUARDS
    assert_match(/max_memory_usage = \d+/, guards)
    assert_match(/max_bytes_before_external_group_by = \d+/, guards)
  end

  test "has_link predicate is derived from SourceTaxonomy (non-organic) and stays consistent" do
    pred = ClickhouseRollupRebuildService.has_link_predicate
    # It is exactly: the source classifier is NOT organic.
    assert_includes pred, Analytics::SourceTaxonomy.expr("events")
    assert_includes pred, "!= 'organic'"
  end

  test "source_expr delegates to the single SourceTaxonomy definition" do
    assert_equal Analytics::SourceTaxonomy.expr("events"),
                 ClickhouseRollupRebuildService.source_expr
  end

  test "install types cover both install and reinstall" do
    types = ClickhouseRollupRebuildService::INSTALL_TYPES_SQL
    assert_includes types, "'install'"
    assert_includes types, "'reinstall'"
  end

  test "acquisition is registered as an unpartitioned, separately-rebuilt rollup" do
    # last_touch + dimension are partition-scoped (in ROLLUPS); acquisition is not (own method).
    assert ClickhouseRollupRebuildService::ROLLUPS.key?(:last_touch)
    assert ClickhouseRollupRebuildService::ROLLUPS.key?(:dimension)
    assert_not ClickhouseRollupRebuildService::ROLLUPS.key?(:acquisition)
    assert_respond_to ClickhouseRollupRebuildService, :rebuild_acquisition
  end

  test "rebuild_acquisition no-ops when ClickHouse writes are disabled" do
    Clickhouse.stub(:enabled?, false) do
      assert_equal false, ClickhouseRollupRebuildService.rebuild_acquisition("202606")
    end
  end

  test "trusted_recompute_sql is built for every model and rejects unknown ones" do
    %i[install first last].each do |model|
      sql = ClickhouseAttributionReadService.trusted_recompute_sql(model)
      assert_includes sql, "uniqExact(active.visitor_id)"
      assert_includes sql, "events"
    end
    assert_raises(ArgumentError) { ClickhouseAttributionReadService.trusted_recompute_sql(:nope) }
  end
end
