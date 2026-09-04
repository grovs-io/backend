# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

# Heavy raw shapes (search, contains/is_not) into cold storage → query_too_heavy;
# plain list stays allowed. Paid project so the retention gate passes for a
# cold-crossing range (hot 365 < start < queryable 730).
class AnalyticsColdZoneShapeTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :stripe_subscriptions, :stripe_payment_intents

  setup do
    @instance = instances(:one) # active_sub -> paid
    @instance.update!(cold_storage_days: 365, delete_days: 730)
    @project = projects(:one)
    @user = users(:admin_user)
    @headers = doorkeeper_headers_for(@user)
  end

  def cold_range = { start_date: (Date.current - 500).to_s, end_date: Date.current.to_s }
  def hot_range  = { start_date: (Date.current - 100).to_s, end_date: Date.current.to_s }
  # <=90d window entirely in cold, so volume's 90-day cap doesn't pre-empt the guard.
  def cold_narrow = { start_date: (Date.current - 450).to_s, end_date: (Date.current - 400).to_s }

  test 'text search reaching into cold storage is rejected as query_too_heavy' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: cold_range.merge(search: 'checkout'), headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
  end

  test 'contains filter reaching into cold storage is rejected as query_too_heavy' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: cold_range.merge(filters: [{ field: 'event_name', operator: 'contains', value: 'pay' }].to_json),
          headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
  end

  test 'plain paginated list reaching into cold storage is allowed' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: cold_range, headers: @headers
    end
    assert_response :ok
    assert_not_equal 'query_too_heavy', (JSON.parse(response.body)['error_code'] rescue nil)
  end

  test 'text search within the hot window is allowed' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events",
          params: hot_range.merge(search: 'checkout'), headers: @headers
    end
    assert_response :ok
    assert_not_equal 'query_too_heavy', (JSON.parse(response.body)['error_code'] rescue nil)
  end

  test 'volume with search reaching into cold storage is rejected as query_too_heavy' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: cold_narrow.merge(search: 'checkout', bucket: 'day'), headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
  end

  test 'field_values with q reaching into cold storage is rejected as query_too_heavy' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/field-values",
          params: cold_narrow.merge(field: 'country', q: 'US'), headers: @headers
    end
    assert_response :unprocessable_entity
    assert_equal 'query_too_heavy', JSON.parse(response.body)['error_code']
  end

  test 'plain aggregate volume into cold storage is allowed' do
    Clickhouse.stub(:read_enabled?, true) do
      get "#{API_PREFIX}/projects/#{@project.id}/analytics/events/volume",
          params: cold_narrow.merge(bucket: 'day'), headers: @headers
    end
    assert_response :ok
    assert_not_equal 'query_too_heavy', (JSON.parse(response.body)['error_code'] rescue nil)
  end
end
