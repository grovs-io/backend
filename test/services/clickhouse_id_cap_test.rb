# frozen_string_literal: true

require "test_helper"

class ClickhouseIdCapTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :link_daily_statistics, :redirect_configs,
           :visitors, :devices

  setup { @shadow_writes_env = ENV.fetch("PG_SHADOW_WRITES", :unset) }
  teardown { restore_shadow_writes }

  def restore_shadow_writes
    if @shadow_writes_env == :unset
      ENV.delete("PG_SHADOW_WRITES")
    else
      ENV["PG_SHADOW_WRITES"] = @shadow_writes_env
    end
  end

  # Restores whatever was there, so a worker configured with PG_SHADOW_WRITES=false keeps it.
  def with_shadow_writes_off
    ENV["PG_SHADOW_WRITES"] = "false"
    yield
  ensure
    restore_shadow_writes
  end

  def with_shadow_writes_on
    ENV["PG_SHADOW_WRITES"] = "true"
    yield
  ensure
    restore_shadow_writes
  end

  def in_list_query(count)
    ids = (1_000_000...(1_000_000 + count)).to_a
    ClickHouse::Client::Query.new(
      raw_query: "SELECT count() AS c FROM numbers(1) WHERE number IN (#{ids.join(',')})",
      placeholders: {}
    )
  end

  # The real cap, not a sample below it: it must clear http_max_field_value_size (128 KiB).
  test "an id list at the cap survives the round trip" do
    skip_unless_clickhouse!
    query = in_list_query(Clickhouse::MAX_IN_LIST_IDS)

    assert_operator query.to_sql.bytesize, :>, 128 * 1024, "must exceed the form-field ceiling"
    assert_equal 0, Clickhouse.with { |conn| conn.select_value(query) }.to_i
  end

  # Pins the max_query_size injection itself, which no cap-sized statement reaches any more.
  test "a statement past the default max_query_size still round trips" do
    skip_unless_clickhouse!
    query = in_list_query(40_000)

    assert_operator query.to_sql.bytesize, :>, 256 * 1024, "must exceed the DEFAULT max_query_size"
    assert_equal 0, Clickhouse.with { |conn| conn.select_value(query) }.to_i
  end

  test "the gate admits exactly the cap and rejects one past it" do
    query = LinkStatisticsQuery.new(params: { sort_by: "installs", ascendent: false }, project: projects(:one))
    ids = Link.where(domain_id: projects(:one).domain.id).where(active: true).pluck(:id)

    assert_operator ids.size, :>=, 2, "fixtures must supply enough links to straddle a cap"
    with_shadow_writes_off do
      query.stub(:metric_sort_id_cap, ids.size) do
        assert_nothing_raised { query.send(:ch_metric_sort_call) }
      end
      query.stub(:metric_sort_id_cap, ids.size - 1) do
        assert_raises(Clickhouse::Unavailable) { query.send(:ch_metric_sort_call) }
      end
    end
  end

  test "over the cap falls back to Postgres while shadow writes still fill the stat tables" do
    with_shadow_writes_on { assert_nil Clickhouse.id_cap_exceeded!(:some_surface, 20_000) }
  end

  test "over the cap fails visibly once the stat tables have gone cold" do
    with_shadow_writes_off do
      error = assert_raises(Clickhouse::Unavailable) { Clickhouse.id_cap_exceeded!(:some_surface, 20_000) }
      assert_match(/some_surface/, error.message)
    end
  end

  # Every gate, both temperatures: warm PG keeps the fallback, cold PG must raise instead.
  def assert_gate(label, &probe)
    with_shadow_writes_off { assert_raises(Clickhouse::Unavailable, label) { probe.call } }
    with_shadow_writes_on { assert_nothing_raised { probe.call } }
  end

  test "the link metric sort gate fails loud only once Postgres is cold" do
    query = LinkStatisticsQuery.new(params: { sort_by: "installs", ascendent: false }, project: projects(:one))
    query.stub(:metric_sort_id_cap, 0) { assert_gate("link metric sort") { query.send(:ch_metric_sort_call) } }
  end

  test "the link revenue sort gate fails loud only once Postgres is cold" do
    query = LinkStatisticsQuery.new(params: { sort_by: "revenue", ascendent: false }, project: projects(:one))
    query.stub(:metric_sort_id_cap, 0) { assert_gate("link revenue sort") { query.send(:ledger_revenue_sort_call) } }
  end

  def with_primary(value)
    previous = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = value
    yield
  ensure
    Rails.application.config.clickhouse_primary = previous
  end

  # Its fallback reads raw `events`, which primary stops writing at once, shadow writes or not.
  test "the link event sort gate fails loud under primary even with shadow writes on" do
    query = EventMetricsQuery.new(project: projects(:one))
    links = Link.where(domain_id: projects(:one).domain.id)
    probe = lambda do
      query.send(:ch_sorted_by_links, links: links, page: 1, event_type: Grovs::Events::VIEW,
                                      asc: false, start_date: Date.new(2026, 3, 1), end_date: Date.new(2026, 3, 2))
    end

    with_shadow_writes_on do
      query.stub(:metric_sort_id_cap, 0) do
        with_primary(true) { assert_raises(Clickhouse::Unavailable) { probe.call } }
        with_primary(false) { assert_nothing_raised { probe.call } }
      end
    end
  end

  test "the visitor term candidate gate fails loud only once Postgres is cold" do
    query = VisitorStatisticsQuery.new(params: { term: "a" }, project: projects(:one))
    query.stub(:term_id_cap, 0) { assert_gate("visitor term") { query.send(:term_candidate_ids) } }
  end

  test "the visitor sorted candidate gate fails loud only once Postgres is cold" do
    query = VisitorStatisticsQuery.new(params: { sort_by: "sdk_identifier" }, project: projects(:one))
    query.stub(:term_id_cap, 0) { assert_gate("visitor sorted") { query.send(:sorted_candidate_ids) } }
  end

  test "the inviter population gate fails loud only once Postgres is cold" do
    query = VisitorReferralStatisticsQuery.new(params: {}, project: projects(:one))
    query.stub(:term_id_cap, 0) do
      ClickhouseReadService.stub(:inviter_population_ids, [1, 2, 3]) do
        assert_gate("inviter population") { query.send(:candidate_scope) }
      end
    end
  end
end
