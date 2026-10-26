# frozen_string_literal: true

require 'test_helper'

class Analytics::RetentionServiceTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @now = Time.current
  end

  # --- summary ---

  test 'summary returns day_1 day_7 day_30 rates with data' do
    insert_retention_data
    result = Analytics::RetentionService.summary(@project.id)
    assert result.key?(:day_1)
    assert result.key?(:day_7)
    assert result.key?(:day_30)
    assert result[:sparkline].is_a?(Array)
  end

  test 'summary returns nils with no data' do
    result = Analytics::RetentionService.summary(@project.id)
    assert_nil result[:day_1]
    assert_nil result[:day_7]
    assert_nil result[:day_30]
    assert_equal [], result[:sparkline]
    assert_nil result[:median_churn_day]
  end

  test 'summary returns nil rates and empty sparkline when no cohorts exist in date window' do
    result = Analytics::RetentionService.summary(
      @project.id,
      start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 31)
    )

    assert_nil result[:day_1]
    assert_nil result[:day_7]
    assert_nil result[:day_30]
    assert_equal [], result[:sparkline]
    assert_nil result[:median_churn_day]
  end

  test 'summary returns safe empty result when ClickHouse read fails' do
    Clickhouse.stub(:with, -> { raise StandardError, 'clickhouse unavailable' }) do
      result = Analytics::RetentionService.summary(@project.id)

      assert_equal(
        { day_1: nil, day_7: nil, day_30: nil, day_1_users: 0, day_7_users: 0, day_30_users: 0,
          sparkline: [], median_churn_day: nil },
        result
      )
    end
  end

  test 'summary propagates ArgumentError' do
    assert_raises(ArgumentError) do
      Analytics::RetentionService.summary('not_a_number')
    end
  end

  # Fix: the platform filter must scope the DENOMINATOR (user_profiles), not just
  # the numerator. 4 iOS installs all retain on D1; 4 Android installs never return.
  # iOS D1 must read 100%, not 50% (which is what an all-platform denominator gives).
  test 'summary platform filter scopes the denominator (user_profiles), not only retention' do
    profiles = []
    visitor_rows = []
    first_seen = (@now - 14.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

    4.times do |i|
      vid = 6000 + i
      profiles << { project_id: @project.id, visitor_id: vid, first_seen: first_seen,
                    last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios' }
      visitor_rows << { project_id: @project.id, visitor_id: vid,
                        event_date: (@now - 13.days).to_date.to_s, event_type: 'OPEN', platform: 'ios',
                        cnt: 1, total_engagement_time: 1000, inviter_id_state: 0 }
    end
    # Android installs that never return — must NOT dilute the iOS denominator.
    4.times do |i|
      profiles << { project_id: @project.id, visitor_id: 6100 + i, first_seen: first_seen,
                    last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'android' }
    end

    insert_ch_user_profiles(profiles)
    insert_ch_visitor_daily(visitor_rows)

    result = Analytics::RetentionService.summary(@project.id, platform: 'ios')
    assert_equal 100.0, result[:day_1], 'iOS D1 should be 4/4, not diluted by Android installs'
  end

  # Today's installs have no finished day 1 yet, so only the two-days-ago cohort shows.
  test 'summary sparkline covers first visits in the range whose day 1 has ended' do
    today = @now.to_date
    two_days_ago = (@now - 2.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([
      { project_id: @project.id, visitor_id: 6200, first_seen: two_days_ago, last_seen: two_days_ago, platform: 'ios' },
      { project_id: @project.id, visitor_id: 6201, first_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
        last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios' }
    ])

    result = Analytics::RetentionService.summary(@project.id, start_date: today - 2, end_date: today)
    dates = result[:sparkline].map { |p| p[:date] }
    assert_equal [(today - 2).to_s], dates
  end

  # Last 7 days still yields D30: it counts users whose day 30 fell inside the range.
  test 'summary returns D30 for a range shorter than 30 days' do
    today = @now.to_date
    first_seen = (@now - 33.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([
      { project_id: @project.id, visitor_id: 6300, first_seen: first_seen, last_seen: first_seen, platform: 'ios' },
      { project_id: @project.id, visitor_id: 6301, first_seen: first_seen, last_seen: first_seen, platform: 'ios' }
    ])
    insert_ch_visitor_daily([vd_row(6300, (@now - 3.days).to_date)])

    result = Analytics::RetentionService.summary(@project.id, start_date: today - 6, end_date: today)
    assert_equal 50.0, result[:day_30]
    assert_equal 2, result[:day_30_users]
  end

  # Day N counts activity on that day only, not any later return.
  test 'summary counts a return on day 2 toward neither D1 nor D7' do
    first_seen = (@now - 10.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([{ project_id: @project.id, visitor_id: 6400, first_seen: first_seen,
                               last_seen: first_seen, platform: 'ios' }])
    insert_ch_visitor_daily([vd_row(6400, (@now - 8.days).to_date), vd_row(6400, (@now - 1.day).to_date)])

    result = Analytics::RetentionService.summary(@project.id)
    assert_equal 0.0, result[:day_1]
    assert_equal 0.0, result[:day_7]
  end

  # A day N that is still today is not counted: the user could still come back.
  test 'summary leaves out users whose day N is today' do
    first_seen = (@now - 7.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([{ project_id: @project.id, visitor_id: 6500, first_seen: first_seen,
                               last_seen: first_seen, platform: 'ios' }])
    insert_ch_visitor_daily([vd_row(6500, (@now - 6.days).to_date)])

    result = Analytics::RetentionService.summary(@project.id)
    assert_equal 100.0, result[:day_1]
    assert_nil result[:day_7]
    assert_equal 0, result[:day_7_users]
  end

  # Duplicate user_profiles rows for one visitor (RMT backfill + live row) must count
  # that visitor once, since the rate query uses countIf on the deduped `up` CTE.
  test 'summary counts a visitor once despite duplicate user_profiles rows' do
    first_seen = (@now - 10.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    # 9500: two profile rows, returns -> retained. 9501: one row, never returns.
    insert_ch_user_profiles([
      { project_id: @project.id, visitor_id: 9500, first_seen: first_seen,
        last_seen: (@now - 9.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios' },
      { project_id: @project.id, visitor_id: 9500, first_seen: first_seen,
        last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios' },
      { project_id: @project.id, visitor_id: 9501, first_seen: first_seen,
        last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios' }
    ])
    insert_ch_visitor_daily([{ project_id: @project.id, visitor_id: 9500,
                               event_date: (@now - 9.days).to_date.to_s, event_type: 'OPEN', platform: 'ios',
                               cnt: 1, total_engagement_time: 1000, inviter_id_state: 0 }])

    # 2 cohort visitors, 1 retained -> 50% (66.7% if the dup were double-counted).
    assert_equal 50.0, Analytics::RetentionService.summary(@project.id)[:day_1]
  end

  # A merged-away id keeps its profile row but its activity lives under the survivor's id.
  test 'summary shows the pre-existing profile-cohort dilution when a raw (pre-merge) id enters the cohort' do
    insert_merged_person
    result = Analytics::RetentionService.summary(@project.id,
                                                  visitor_clause: "up.visitor_id IN (#{@raw_id}, #{@survivor_id})")
    assert_equal 50.0, result[:day_1], 'the raw id counts toward total but is never retained — vm has no row for it'
  end

  # effective: true yields only the survivor id, so the merged person is one cohort member.
  test 'summary is not diluted by a merged-away raw id when the clause carries only the effective id' do
    insert_merged_person
    result = Analytics::RetentionService.summary(@project.id, visitor_clause: "up.visitor_id IN (#{@survivor_id})")
    assert_equal 100.0, result[:day_1]
  end

  # Active on days 1, 7, 14, 30 but not 3: exact D3 dips, yet nobody has churned.
  test 'summary median churn day is not set by one quiet day' do
    first_seen = (@now - 35.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([{ project_id: @project.id, visitor_id: 6600, first_seen: first_seen,
                               last_seen: first_seen, platform: 'ios' }])
    insert_ch_visitor_daily([1, 7, 14, 30, 34].map { |d| vd_row(6600, (@now - 35.days).to_date + d) })

    result = Analytics::RetentionService.summary(@project.id)
    assert_equal 100.0, result[:day_30]
    assert_nil result[:median_churn_day]
  end

  test 'summary median churn day is the first day most users are gone for good' do
    first_seen = (@now - 20.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles((6700..6703).map do |vid|
      { project_id: @project.id, visitor_id: vid, first_seen: first_seen, last_seen: first_seen, platform: 'ios' }
    end)
    start = (@now - 20.days).to_date
    insert_ch_visitor_daily([vd_row(6700, start + 10), vd_row(6701, start + 2), vd_row(6702, start + 1)])

    # Still active on or after day 1: 3/4, day 3: 1/4.
    assert_equal 3, Analytics::RetentionService.summary(@project.id)[:median_churn_day]
  end

  test 'summary median churn day counts a return today' do
    first_seen = (@now - 35.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([{ project_id: @project.id, visitor_id: 6800, first_seen: first_seen,
                               last_seen: first_seen, platform: 'ios' }])
    insert_ch_visitor_daily([vd_row(6800, @now.to_date)])

    assert_nil Analytics::RetentionService.summary(@project.id)[:median_churn_day]
  end

  # A return after the range end still means the user did not churn.
  test 'summary median churn day counts returns after the selected range' do
    today = @now.to_date
    first_seen = (@now - 20.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([{ project_id: @project.id, visitor_id: 6900, first_seen: first_seen,
                               last_seen: first_seen, platform: 'ios' }])
    insert_ch_visitor_daily([vd_row(6900, today - 2)])

    result = Analytics::RetentionService.summary(@project.id, start_date: today - 20, end_date: today - 10)
    assert_equal 0.0, result[:day_1]
    assert_nil result[:median_churn_day]
  end

  private

  def vd_row(visitor_id, date)
    { project_id: @project.id, visitor_id: visitor_id, event_date: date.to_s, event_type: 'OPEN',
      platform: 'ios', cnt: 1, total_engagement_time: 1000, inviter_id_state: 0 }
  end

  def insert_merged_person
    @raw_id = 7001
    @survivor_id = 7002
    first_seen = (@now - 14.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')
    insert_ch_user_profiles([
      { project_id: @project.id, visitor_id: @raw_id, first_seen: first_seen, last_seen: first_seen, platform: 'ios' },
      { project_id: @project.id, visitor_id: @survivor_id, first_seen: first_seen,
        last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios' }
    ])
    # Only the survivor id appears in visitor_daily — the raw id's activity moved at merge time.
    insert_ch_visitor_daily([{ project_id: @project.id, visitor_id: @survivor_id,
                               event_date: (@now - 13.days).to_date.to_s, event_type: 'OPEN', platform: 'ios',
                               cnt: 1, total_engagement_time: 1000, inviter_id_state: 0 }])
  end

  def insert_retention_data
    profiles = []
    visitor_rows = []

    # Create 10 users with first_seen 14 days ago
    10.times do |i|
      visitor_id = 5000 + i
      first_seen = (@now - 14.days).utc.strftime('%Y-%m-%d %H:%M:%S.%3N')

      profiles << {
        project_id: @project.id,
        visitor_id: visitor_id,
        first_seen: first_seen,
        last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
        platform: 'ios'
      }

      # Half of them return on day 1
      if i < 5
        visitor_rows << {
          project_id: @project.id,
          visitor_id: visitor_id,
          event_date: (@now - 13.days).to_date.to_s,
          event_type: 'OPEN',
          platform: 'ios',
          cnt: 1,
          total_engagement_time: 1000,
          inviter_id_state: 0
        }
      end

      # 3 of them return on day 7
      if i < 3
        visitor_rows << {
          project_id: @project.id,
          visitor_id: visitor_id,
          event_date: (@now - 7.days).to_date.to_s,
          event_type: 'OPEN',
          platform: 'ios',
          cnt: 1,
          total_engagement_time: 1000,
          inviter_id_state: 0
        }
      end
    end

    insert_ch_user_profiles(profiles)
    insert_ch_visitor_daily(visitor_rows)
  end
end

class Analytics::RetentionServiceVisitorClauseTest < ActiveSupport::TestCase
  include AnalyticsSqlCaptureHelper

  PID = 8_800
  # An always-on WHERE added to the unfiltered queries must fail these.
  RATES_TAIL = 'LEFT JOIN ret r ON r.visitor_id = up.visitor_id SETTINGS max_execution_time'
  SPARKLINE_TAIL = 'LEFT JOIN ret r ON r.visitor_id = up.visitor_id GROUP BY cohort_date'

  test 'summary appends visitor_clause to both the rates query and the sparkline query' do
    clause = 'up.visitor_id IN (1, 2)'
    sqls = capture_stubbed_ch_sql { Analytics::RetentionService.summary(PID, visitor_clause: clause) }
    assert_equal 2, sqls.size
    sqls.each { |sql| assert_includes sql, clause }
  end

  test 'summary with visitor_clause nil matches omitting it, on the frozen unfiltered WHEREs, with no segment_results' do
    baseline = capture_stubbed_ch_sql { Analytics::RetentionService.summary(PID) }
    with_nil = capture_stubbed_ch_sql { Analytics::RetentionService.summary(PID, visitor_clause: nil) }
    assert_equal baseline, with_nil
    baseline.each { |sql| assert_not_includes sql, 'segment_results' }
    assert_includes baseline[0], RATES_TAIL
    assert_includes baseline[1], SPARKLINE_TAIL
  end
end
