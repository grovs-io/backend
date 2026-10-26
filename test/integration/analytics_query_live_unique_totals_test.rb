# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'
require_relative 'analytics_schema_helper'

class AnalyticsQueryLiveUniqueTotalsTest < ActionDispatch::IntegrationTest
  include AuthTestHelper
  include AnalyticsSchemaHelper
  include ClickhouseTestHelper

  fixtures :instances, :users, :instance_roles, :projects

  setup do
    skip_unless_clickhouse!
    @ch_auto_rebuild_breakdowns = true
    @project = projects(:one)
    @url = "#{API_PREFIX}/projects/#{@project.id}/analytics/query"
  end

  teardown { Rails.cache.clear }

  def ev(id, visitor, days_ago, platform)
    { event_id: "live_uq_#{id}", project_id: @project.id, event_type: Grovs::Events::APP_OPEN, link_id: 0,
      visitor_id: visitor, device_id: visitor, platform: platform,
      created_at: ((Date.current - days_ago).to_time(:utc) + 12.hours).strftime('%Y-%m-%d %H:%M:%S.%3N') }
  end

  test 'the live endpoint returns exact unique totals with other and compare, inside the response contract' do
    insert_ch_events([ev(1, 901, 1, 'ios'), ev(2, 901, 1, 'android'), ev(3, 902, 1, 'android'), ev(4, 901, 1, 'mac'),
                      ev(5, 903, 20, 'ios'), ev(6, 903, 20, 'android')])
    Clickhouse.stub(:read_enabled?, true) do
      get @url, params: { metric: 'unique_visitors', group_by: 'platform', limit: '1', compare: 'true', granularity: 'week',
                          start_date: (Date.current - 13).to_s, end_date: Date.current.to_s }, headers: doorkeeper_headers_for(users(:admin_user))
    end
    assert_response :ok
    assert_analytics_schema(:metric_query)
    body = JSON.parse(response.body)
    assert_equal [['android', 2, 1]], body['rows'].map { |r| [r['key'], r['value'], r['previous']] }
    assert_equal [1, 1], [body['other']['value'], body['other']['previous']], 'ios+mac hold only visitor 901 now and 903 before'
    assert_equal({ 'value' => 2, 'previous' => 1 }, body['total'], 'rows+other is 3 now and 2 before; visitors are 2 and 1')
  end
end
