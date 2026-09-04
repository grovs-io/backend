# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

class AnalyticsRetentionGateLegacyTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :stripe_subscriptions, :stripe_payment_intents

  setup do
    @free_instance = instances(:two)
    @free_instance.update!(cold_storage_days: 365, delete_days: 730)
    @free_project = projects(:two)
    @free_user = users(:super_admin_user)

    @paid_instance = instances(:one)
    @paid_instance.update!(cold_storage_days: 365, delete_days: 730)
    @paid_project = projects(:one)
    @paid_user = users(:admin_user)
  end

  GATED_ROUTES = {
    'dashboard/metrics_overview' => 'dashboard#metrics_overview',
    'dashboard/top_links' => 'dashboard#best_performing_links',
    'events/search' => 'events#events_for_search_params',
    'events/sorted' => 'events#events_sorted_by_param',
    'events/overview' => 'events#events_for_overview',
    'campaigns/search_v2' => 'campaigns#current_project_campaigns_v2',
    'campaigns/metrics_overview' => 'campaigns#metrics_for_overview',
    'links/search_v2' => 'links#current_project_links_v2',
    'visitors/search' => 'visitors#visitors',
    'visitors/aggregated' => 'visitors#aggregated_visitors',
    'exports/links' => 'export#export_link_data'
  }.freeze

  # PG-only readers: the gate must never fire on them, even with ClickHouse enabled.
  UNGATED_ROUTES = {
    'campaigns/search' => 'campaigns#current_project_campaigns',
    'links/search' => 'links#current_project_links'
  }.freeze

  UNGATED_ROUTES.each do |route, action|
    test "#{action} is never retention-gated (PostgreSQL-only reader)" do
      post_as(@free_user, @free_project, route, start_date: (Date.current - 400).to_s)

      assert_response :success
    end
  end

  GATED_ROUTES.each do |route, action|
    test "#{action} rejects a free project reaching past the hot window" do
      post_as(@free_user, @free_project, route, start_date: (Date.current - 400).to_s)

      assert_response :unprocessable_entity
      assert_equal 'retention_window_exceeded', JSON.parse(response.body)['error_code']
    end

    test "#{action} allows a free project inside the hot window" do
      post_as(@free_user, @free_project, route, start_date: (Date.current - 100).to_s)

      assert_response :success
    end

    test "#{action} allows a paid project past the free hot window" do
      post_as(@paid_user, @paid_project, route, start_date: (Date.current - 500).to_s)

      assert_response :success
    end
  end

  test 'gate is inert when ClickHouse is not the analytics read source' do
    Clickhouse.stub(:analytics_rollups_read_enabled?, false) do
      post "#{API_PREFIX}/projects/#{@free_project.id}/dashboard/metrics_overview",
           params: { start_date: (Date.current - 400).to_s, end_date: Date.current.to_s },
           headers: doorkeeper_headers_for(@free_user)
    end

    assert_not_equal 'retention_window_exceeded', error_code
  end

  test 'a project past delete_days is rejected even on a paid plan' do
    post_as(@paid_user, @paid_project, 'dashboard/metrics_overview', start_date: (Date.current - 800).to_s)

    assert_response :unprocessable_entity
    assert_equal 'retention_window_exceeded', JSON.parse(response.body)['error_code']
  end

  test 'an absent start_date is allowed when the window exceeds the 30-day default' do
    post_as(@free_user, @free_project, 'dashboard/metrics_overview', {})

    assert_not_equal 'retention_window_exceeded', error_code
  end

  test 'an absent start_date is rejected when the window is shorter than the 30-day default' do
    @free_instance.update!(cold_storage_days: 7, delete_days: 7)

    post_as(@free_user, @free_project, 'dashboard/metrics_overview', {})

    assert_response :unprocessable_entity
    assert_equal 'retention_window_exceeded', JSON.parse(response.body)['error_code']
  end

  test 'billing metrics stay readable past the retention window' do
    Clickhouse.stub(:analytics_rollups_read_enabled?, true) do
      post "#{API_PREFIX}/instances/#{@free_instance.id}/events/billing",
           params: { start_date: (Date.current - 800).to_s, end_date: Date.current.to_s },
           headers: doorkeeper_headers_for(@free_user)
    end

    assert_not_equal 'retention_window_exceeded', error_code
  end

  private

  # Every route's contract permits these; the events routes require them to reach a 2xx.
  def baseline_params
    { end_date: Date.current.to_s, archived: false, page: 1, event_type: 'view', active: true, sdk: false }
  end

  def post_as(user, project, route, params)
    Clickhouse.stub(:analytics_rollups_read_enabled?, true) do
      post "#{API_PREFIX}/projects/#{project.id}/#{route}",
           params: baseline_params.merge(params),
           headers: doorkeeper_headers_for(user)
    end
  end

  def error_code
    JSON.parse(response.body)['error_code']
  rescue JSON::ParserError
    nil
  end
end
