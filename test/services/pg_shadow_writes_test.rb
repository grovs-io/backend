# frozen_string_literal: true

require "test_helper"

class PgShadowWritesTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices, :links, :domains, :redirect_configs,
           :visitor_daily_statistics, :link_daily_statistics

  setup do
    @project = projects(:one)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
    @date = Date.new(2026, 6, 23)
    VisitorDailyStatistic.where(project_id: @project.id).delete_all
    LinkDailyStatistic.where(project_id: @project.id).delete_all
    DailyProjectMetric.where(project_id: @project.id).delete_all
    ProjectDailyActiveUser.where(project_id: @project.id).delete_all
  end

  teardown { ENV.delete("PG_SHADOW_WRITES") }

  def with_shadow_writes_off
    ENV["PG_SHADOW_WRITES"] = "false"
    yield
  ensure
    ENV.delete("PG_SHADOW_WRITES")
  end

  test "the flag defaults on so nothing changes until it is deliberately flipped" do
    assert Grovs.pg_shadow_writes?
  end

  test "only an explicitly falsey value goes cold — a one-way flip must not hinge on formatting" do
    ["1", "TRUE", "yes", "on", "", "banana"].each do |value|
      ENV["PG_SHADOW_WRITES"] = value
      assert Grovs.pg_shadow_writes?, "#{value.inspect} must keep shadow writes on"
    end

    ["false", "FALSE", "0", "off", "f"].each do |value|
      ENV["PG_SHADOW_WRITES"] = value
      assert_not Grovs.pg_shadow_writes?, "#{value.inspect} must disable shadow writes"
    end
  end

  test "boot refuses shadow writes off without a ClickHouse primary to answer instead" do
    assert_raises(RuntimeError) do
      Clickhouse.validate_shadow_writes_wiring!(primary: false, shadow_writes: false)
    end

    assert_nothing_raised do
      Clickhouse.validate_shadow_writes_wiring!(primary: true, shadow_writes: false)
      Clickhouse.validate_shadow_writes_wiring!(primary: false, shadow_writes: true)
    end
  end

  test "a ledger failure raises instead of serving the cold stat tables' zeros" do
    failing = -> { raise ActiveRecord::StatementInvalid, "ledger down" }

    with_shadow_writes_off do
      assert_raises(RevenueLedger::Unavailable) do
        RevenueLedgerQuery.send(:guarded, :project_totals, &failing)
      end
    end

    assert_nil RevenueLedgerQuery.send(:guarded, :project_totals, &failing)
  end

  test "under primary a ledger failure raises even while the stat tables are still warm" do
    Rails.application.config.clickhouse_primary = true

    assert Grovs.pg_shadow_writes?
    assert_raises(RevenueLedger::Unavailable) do
      RevenueLedgerQuery.send(:guarded, :project_totals) { raise ActiveRecord::StatementInvalid, "down" }
    end
  end

  test "product totals keep degrading — their fallback table is deliberately never gated" do
    with_shadow_writes_off do
      RevenueLedgerQuery.stub(:product_totals_sql, ->(*) { raise ActiveRecord::StatementInvalid, "down" }) do
        assert_nil RevenueLedgerQuery.product_totals(@project.id, start_date: @date, end_date: @date)
      end
    end
  end

  test "visitor stat writes stop" do
    with_shadow_writes_off do
      assert_no_difference "VisitorDailyStatistic.count" do
        VisitorDailyStatService.increment_visitor_event(
          visitor: @visitor, event_type: :views, platform: "ios",
          event_date: @date, project_id: @project.id
        )
        VisitorDailyStatService.bulk_upsert_visitor_stats([{
          project_id: @project.id, visitor_id: @visitor.id, event_date: @date,
          platform: "ios", metrics: { views: 1 }
        }])
      end
    end
  end

  test "visitor stat writes still land with the flag on" do
    assert_difference "VisitorDailyStatistic.count", 1 do
      VisitorDailyStatService.increment_visitor_event(
        visitor: @visitor, event_type: :views, platform: "ios",
        event_date: @date, project_id: @project.id
      )
    end
  end

  test "an invalid event type still raises with the flag off" do
    with_shadow_writes_off do
      assert_raises(ArgumentError) do
        VisitorDailyStatService.increment_visitor_event(
          visitor: @visitor, event_type: :nonsense, platform: "ios",
          event_date: @date, project_id: @project.id
        )
      end
    end
  end

  test "link stat writes stop" do
    with_shadow_writes_off do
      assert_no_difference "LinkDailyStatistic.count" do
        LinkDailyStatService.increment_link_event(
          event_type: :views, project_id: @project.id, link_id: @link.id,
          platform: "ios", event_date: @date
        )
        LinkDailyStatService.bulk_upsert_link_stats([{
          project_id: @project.id, link_id: @link.id, event_date: @date,
          platform: "ios", metrics: { views: 1 }
        }])
      end
    end
  end

  test "link stat writes still land with the flag on" do
    assert_difference "LinkDailyStatistic.count", 1 do
      LinkDailyStatService.increment_link_event(
        event_type: :views, project_id: @project.id, link_id: @link.id,
        platform: "ios", event_date: @date
      )
    end
  end

  test "daily project metric writes stop" do
    with_shadow_writes_off do
      assert_no_difference "DailyProjectMetric.count" do
        DailyProjectMetric.increment!(@project.id, "ios", @date, revenue: 100)
      end
    end
  end

  test "daily project metric writes still land with the flag on" do
    assert_difference "DailyProjectMetric.count", 1 do
      DailyProjectMetric.increment!(@project.id, "ios", @date, revenue: 100)
    end
  end

  test "both generators stop, including their direct callers" do
    VisitorDailyStatService.increment_visitor_event(
      visitor: @visitor, event_type: :views, platform: "ios",
      event_date: @date, project_id: @project.id
    )

    with_shadow_writes_off do
      assert_no_difference ["DailyProjectMetric.count", "ProjectDailyActiveUser.count"] do
        DailyProjectMetricsGenerator.call(@date)
        ProjectDailyActiveUsersGenerator.call(@date)
      end
    end
  end

  test "both generators still run with the flag on" do
    VisitorDailyStatService.increment_visitor_event(
      visitor: @visitor, event_type: :views, platform: "ios",
      event_date: @date, project_id: @project.id
    )

    assert_difference ["DailyProjectMetric.count", "ProjectDailyActiveUser.count"], 1 do
      DailyProjectMetricsGenerator.call(@date)
      ProjectDailyActiveUsersGenerator.call(@date)
    end
  end

  test "the flush endpoint reports the skip instead of claiming aggregated dates" do
    with_shadow_writes_off do
      result = EventFlushService.flush

      assert_empty result[:dates_aggregated]
      assert result[:aggregation_skipped]
    end
  end

  test "the flush endpoint still aggregates with the flag on" do
    result = EventFlushService.flush

    assert_equal [Date.today.to_s], result[:dates_aggregated]
    assert_not result[:aggregation_skipped]
  end
end
