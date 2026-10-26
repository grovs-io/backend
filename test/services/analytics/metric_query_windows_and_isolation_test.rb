# frozen_string_literal: true

require 'test_helper'

class Analytics::MetricQueryWindowsAndIsolationTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances, :domains, :links, :campaigns

  RAW = '[{"field":"os","operator":"is_not","value":"__none__"}]'

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @seq = 0
  end

  teardown { Rails.cache.clear }

  def ev(on, type: Grovs::Events::INSTALL, project: @project, **attrs)
    @seq += 1
    { event_id: "mw_#{@seq}", project_id: project.id, event_type: type, link_id: 0, visitor_id: 5000 + @seq,
      device_id: 5000 + @seq, platform: 'ios', created_at: (on.to_time(:utc) + 12.hours).strftime('%Y-%m-%d %H:%M:%S.%3N') }.merge(attrs)
  end

  def build(params = {}, start_date: Date.current - 13, end_date: Date.current, cutoff: nil, **rest)
    Analytics::MetricQuery.build(ActionController::Parameters.new({ metric: 'installs' }.merge(params).merge(rest)),
                                 start_date: start_date, end_date: end_date, cutoff: cutoff)
  end

  def both_paths(params = {}, start_date: Date.current - 13, end_date: Date.current, cutoff: nil, **rest)
    params = params.merge(rest)
    opts = { start_date: start_date, end_date: end_date, cutoff: cutoff }
    [build(params, **opts), build(params.merge(filters: RAW), **opts)].map do |q|
      Analytics::MetricQueryService.run(@project.id, q)
    end
  end

  test 'each counter metric counts only its own event type, link-only metrics need a link' do
    link_id = links(:basic_link).id
    d = Date.current - 1
    insert_ch_events([
      ev(d, type: Grovs::Events::VIEW), ev(d, type: Grovs::Events::VIEW, link_id: link_id),
      ev(d, type: Grovs::Events::OPEN), ev(d), ev(d, link_id: link_id),
      ev(d, type: Grovs::Events::REINSTALL), ev(d, type: Grovs::Events::APP_OPEN),
      ev(d, type: Grovs::Events::USER_REFERRED), ev(d, type: Grovs::Events::CUSTOM, event_name: 'checkout'),
      ev(d, type: Grovs::Events::TIME_SPENT)
    ])
    expected = { 'events' => 10, 'views' => 2, 'link_views' => 1, 'opens' => 1, 'installs' => 2,
                 'link_driven_installs' => 1, 'reinstalls' => 1, 'app_opens' => 1, 'referred_users' => 1 }
    assert_equal Analytics::MetricQuery::COUNTERS.keys.sort, expected.keys.sort
    expected.each do |metric, count|
      rollup, raw = both_paths(metric: metric)
      assert_equal count, raw[:total][:value], "#{metric} raw"
      assert_equal count, rollup[:total][:value], "#{metric} default path"
    end
  end

  test 'day windows start at start_date, include end_date and drop the days outside' do
    sd = Date.current - 6
    ed = Date.current - 2
    insert_ch_events([ev(sd - 1), ev(sd), ev(sd), ev(ed), ev(ed + 1)])
    both_paths({ granularity: 'day' }, start_date: sd, end_date: ed).each_with_index do |r, i|
      points = r[:rows][0][:points]
      assert_equal (sd..ed).map(&:to_s), points.map { |p| p[:date] }, "path #{i}"
      assert_equal [2, 0, 0, 0, 1], points.map { |p| p[:value] }, "path #{i}"
      assert_equal 3, r[:total][:value], "path #{i}"
    end
  end

  test 'month windows are range-relative; the anniversary day opens the next window' do
    sd = Date.current - 70
    ed = Date.current
    insert_ch_events([ev(sd - 1), ev(sd), ev((sd >> 1) - 1), ev(sd >> 1), ev(ed)])
    both_paths({ granularity: 'month' }, start_date: sd, end_date: ed).each_with_index do |r, i|
      points = r[:rows][0][:points]
      assert_equal [sd, sd >> 1, sd >> 2].map(&:to_s), points.map { |p| p[:date] }, "path #{i}"
      assert_equal [2, 1, 1], points.map { |p| p[:value] }, "path #{i}"
      assert_equal 4, r[:total][:value], "path #{i}"
    end
  end

  test 'monthly unique visitors dedup across windows in the row and the total' do
    sd = Date.current - 70
    insert_ch_events([ev(sd, visitor_id: 77), ev(sd >> 1, visitor_id: 77), ev(sd >> 1, visitor_id: 78)])
    both_paths({ metric: 'unique_visitors', granularity: 'month' }, start_date: sd).each_with_index do |r, i|
      assert_equal [1, 2, 0], r[:rows][0][:points].map { |p| p[:value] }, "path #{i}"
      assert_equal 2, r[:rows][0][:value], "path #{i}"
      assert_equal 2, r[:total][:value], "path #{i}"
    end
  end

  test 'compare never reads before the retention cutoff' do
    insert_ch_events([ev(Date.current - 20), ev(Date.current - 16), ev(Date.current - 1)])
    both_paths({ compare: 'true' }).each do |r|
      assert_equal({ value: 1, previous: 2 }, r[:total], 'without a cutoff the full previous period counts')
    end
    both_paths({ compare: 'true' }, cutoff: Date.current - 18).each do |r|
      assert_equal({ value: 1, previous: 1 }, r[:total], 'the day-20 event is past retention')
      assert_equal 1, r[:rows][0][:previous]
    end
  end

  test 'a cutoff at the start day leaves an empty previous period' do
    insert_ch_events([ev(Date.current - 16), ev(Date.current - 1)])
    both_paths({ compare: 'true', group_by: 'country' }, cutoff: Date.current - 13).each do |r|
      assert_equal({ value: 1, previous: 0 }, r[:total])
      assert_nil r[:other]
    end
  end

  test 'another project cannot claim a top-N slot or add to rows, other and totals' do
    other = projects(:two)
    d = Date.current - 1
    insert_ch_events(Array.new(5) { ev(d, project: other, country: 'US') } +
                     [ev(d, country: 'RO'), ev(d, country: 'RO'), ev(d, country: 'DE')])
    %w[installs unique_visitors].each do |metric|
      both_paths(metric: metric, group_by: 'country', limit: '1').each_with_index do |r, i|
        assert_equal({ 'RO' => 2 }, r[:rows].to_h { |x| [x[:key], x[:value]] }, "#{metric} path #{i}")
        assert_equal 1, r[:other][:value], "#{metric} path #{i}"
        assert_equal 3, r[:total][:value], "#{metric} path #{i}"
      end
    end
  end

  test 'a limit equal to the number of keys yields no other bucket' do
    d = Date.current - 1
    insert_ch_events([ev(d, country: 'RO'), ev(d, country: 'DE'), ev(d, country: 'FR')])
    both_paths(group_by: 'country', limit: '3').each do |r|
      assert_equal %w[DE FR RO], r[:rows].map { |x| x[:key] }, 'ties sort by key'
      assert_nil r[:other]
    end
    both_paths(group_by: 'country', limit: '2').each do |r|
      assert_equal %w[DE FR], r[:rows].map { |x| x[:key] }
      assert_equal 1, r[:other][:value]
    end
  end

  test 'campaign rows are labelled from Postgres; unknown ids and nameless links fall back to the id' do
    link = links(:second_link)
    link.update_column(:name, '')
    campaign = campaigns(:one)
    d = Date.current - 1
    insert_ch_events([ev(d, campaign_id: campaign.id), ev(d, campaign_id: campaign.id), ev(d, campaign_id: 987_654),
                      ev(d, campaign_id: 0), ev(d, link_id: link.id)])
    by_campaign = Analytics::MetricQueryService.run(@project.id, build(group_by: 'campaign_id'))
    labels = by_campaign[:rows].to_h { |x| [x[:key], [x[:label], x[:value]]] }
    assert_equal({ campaign.id.to_s => [campaign.name, 2], '987654' => ['987654', 1], '0' => ['(none)', 2] }, labels)

    by_link = Analytics::MetricQueryService.run(@project.id, build(group_by: 'link_id'))
    assert_equal link.id.to_s, by_link[:rows].find { |x| x[:key] == link.id.to_s }[:label]
  end

  test 'a free-form property breakdown skips events without it; a user attribute buckets them as (none)' do
    d = Date.current - 1
    insert_ch_events([
      ev(d, properties: { 'color' => 'red' }, sdk_attributes: { 'tier' => 'gold' }),
      ev(d, properties: { 'color' => 'red' }, sdk_attributes: { 'tier' => 'gold' }),
      ev(d, properties: { 'color' => 'blue' }), ev(d)
    ])
    color = Analytics::MetricQueryService.run(@project.id, build(group_by: 'properties.color'))
    assert_equal({ 'red' => 2, 'blue' => 1 }, color[:rows].to_h { |x| [x[:key], x[:value]] })
    assert_equal 3, color[:total][:value]

    tier = Analytics::MetricQueryService.run(@project.id, build(group_by: 'user.tier'))
    assert_equal({ 'gold' => [2, 'gold'], '' => [2, '(none)'] }, tier[:rows].to_h { |x| [x[:key], [x[:value], x[:label]]] })
    assert_equal 4, tier[:total][:value]
  end

  test 'a SQL failure off primary degrades to an empty result and is not cached' do
    insert_ch_events([ev(Date.current - 1, country: 'RO')])
    q = build(group_by: 'country')
    with_memory_cache do
      broken = ->(_sql) { raise ClickHouse::Client::DatabaseError, 'Code: 47. Unknown identifier' }
      r = Clickhouse.stub(:primary?, false) { Analytics::MetricQueryService.stub(:with_guard, broken) { Analytics::MetricQueryService.run(@project.id, q) } }
      assert_equal({ metric: 'installs', group_by: 'country', rows: [], other: nil, total: { value: 0 } }, r)

      healed = Clickhouse.stub(:primary?, false) { Analytics::MetricQueryService.run(@project.id, q) }
      assert_equal 1, healed[:total][:value], 'the fallback must not be served from cache'
    end
  end

  test 'a too-heavy query and a primary outage propagate instead of returning zeros' do
    q = build(group_by: 'country')
    heavy = ->(_sql) { raise Analytics::QueryTooHeavy, 'too many rows' }
    Clickhouse.stub(:primary?, false) do
      assert_raises(Analytics::QueryTooHeavy) { Analytics::MetricQueryService.stub(:with_guard, heavy) { Analytics::MetricQueryService.run(@project.id, q) } }
    end
    down = ->(_sql) { raise Errno::ECONNREFUSED }
    Clickhouse.stub(:primary?, true) do
      assert_raises(Clickhouse::Unavailable) { Analytics::MetricQueryService.stub(:with_guard, down) { Analytics::MetricQueryService.run(@project.id, q) } }
    end
  end

  private

  def with_memory_cache
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous_cache
  end
end
