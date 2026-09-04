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
        { day_1: nil, day_7: nil, day_30: nil, sparkline: [], median_churn_day: nil },
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

  # Fix: the sparkline boundary must include the FULL end-day. An install at noon
  # today must appear in today's sparkline bucket (a DateTime<=midnight comparison
  # would drop it).
  test 'summary sparkline includes installs on the end day' do
    today = @now.to_date
    insert_ch_user_profiles([{ project_id: @project.id, visitor_id: 6200,
                               first_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'),
                               last_seen: @now.utc.strftime('%Y-%m-%d %H:%M:%S.%3N'), platform: 'ios' }])

    result = Analytics::RetentionService.summary(@project.id, start_date: today - 2, end_date: today)
    dates = result[:sparkline].map { |p| p[:date] }
    assert_includes dates, today.to_s, 'end-day installs must appear in the sparkline'
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
                               event_date: (@now - 8.days).to_date.to_s, event_type: 'OPEN', platform: 'ios',
                               cnt: 1, total_engagement_time: 1000, inviter_id_state: 0 }])

    # 2 cohort visitors, 1 retained -> 50% (66.7% if the dup were double-counted).
    assert_equal 50.0, Analytics::RetentionService.summary(@project.id)[:day_1]
  end

  private

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
