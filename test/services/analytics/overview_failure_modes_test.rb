# frozen_string_literal: true

require 'test_helper'

class Analytics::OverviewFailureModesTest < ActiveSupport::TestCase
  include ClickhouseTestHelper

  fixtures :projects, :instances

  setup do
    skip_unless_clickhouse!
    @project = projects(:one)
    @now = Time.current
    @sd = 7.days.ago.to_date
    @ed = Date.current
  end

  # version_distribution release_date is global first-seen
  test 'version_distribution release_date is global first-seen not date-range-scoped' do
    # Version 1.5.0 first seen in January (outside report range)
    insert_ch_events([
      {
        project_id: @project.id, event_type: 'VIEW', app_version: '1.5.0',
        visitor_id: 7000, platform: 'ios',
        created_at: '2026-01-15 10:00:00.000'
      },
      {
        project_id: @project.id, event_type: 'VIEW', app_version: '1.5.0',
        visitor_id: 7001, platform: 'ios',
        created_at: '2026-05-10 10:00:00.000'
      },
      {
        project_id: @project.id, event_type: 'VIEW', app_version: '2.0.0',
        visitor_id: 7002, platform: 'ios',
        created_at: '2026-05-05 10:00:00.000'
      }
    ])

    result = Analytics::OverviewStatsService.version_distribution(
      @project.id,
      start_date: '2026-05-01',
      end_date: '2026-05-15'
    )

    entries = result[:entries]
    v150 = entries.find { |e| e[:version] == '1.5.0' }
    v200 = entries.find { |e| e[:version] == '2.0.0' }

    assert_not_nil v150
    assert_equal '2026-01-15', v150[:release_date],
                 'Release date should be global first-seen (January), not scoped to report range'

    assert_not_nil v200
    assert_equal '2026-05-05', v200[:release_date]
  end
end
