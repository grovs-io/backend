# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

class AnalyticsRetentionGateTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :stripe_subscriptions, :stripe_payment_intents

  ROUTE = 'analytics/overview/trends/users'

  setup do
    # instance two = free (canceled sub only); super_admin_user is admin on it.
    @free_instance = instances(:two)
    @free_instance.update!(cold_storage_days: 365, delete_days: 730)
    @free_project = projects(:two)
    @free_user = users(:super_admin_user)

    # instance one = paid (active_sub); admin_user is admin on it.
    @paid_instance = instances(:one)
    @paid_instance.update!(cold_storage_days: 365, delete_days: 730)
    @paid_project = projects(:one)
    @paid_user = users(:admin_user)
  end

  test 'free project asking past the hot window is rejected with retention_window_exceeded' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@free_project.id}/#{ROUTE}",
          params: { start_date: (Date.current - 400).to_s, end_date: Date.current.to_s },
          headers: doorkeeper_headers_for(@free_user)
    end

    assert_response :unprocessable_entity
    assert_equal 'retention_window_exceeded', JSON.parse(response.body)['error_code']
  end

  test 'free project within the hot window is not a retention rejection' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@free_project.id}/#{ROUTE}",
          params: { start_date: (Date.current - 100).to_s, end_date: Date.current.to_s },
          headers: doorkeeper_headers_for(@free_user)
    end

    assert_not_equal 'retention_window_exceeded',
                 (JSON.parse(response.body)['error_code'] rescue nil)
  end

  test 'paid project may query past the free hot window (up to delete_days)' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@paid_project.id}/#{ROUTE}",
          params: { start_date: (Date.current - 500).to_s, end_date: Date.current.to_s },
          headers: doorkeeper_headers_for(@paid_user)
    end

    assert_not_equal 'retention_window_exceeded',
                 (JSON.parse(response.body)['error_code'] rescue nil)
  end
end
