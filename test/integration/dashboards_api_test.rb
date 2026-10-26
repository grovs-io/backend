# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

class DashboardsApiTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :dashboards, :dashboard_widgets

  setup do
    @admin_user = users(:admin_user)
    @member_user = users(:member_user)
    @project = projects(:one)
    @other_project = projects(:two)
    @dashboard = dashboards(:one)
    @headers = doorkeeper_headers_for(@admin_user)
    @base = "#{API_PREFIX}/projects/#{@project.id}/dashboards"
  end

  test 'index requires auth and project membership' do
    get @base, headers: api_headers
    assert_response :unauthorized
    get "#{API_PREFIX}/projects/#{@other_project.id}/dashboards", headers: @headers
    assert_response :forbidden
  end

  test 'index lists dashboards with ordered widgets' do
    get @base, headers: @headers
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal ['Growth'], json['dashboards'].map { |d| d['name'] }
    assert_equal ['Installs by country', 'Opens'], json['dashboards'][0]['widgets'].map { |w| w['title'] }
  end

  test 'members can create, rename and delete a dashboard' do
    headers = doorkeeper_headers_for(@member_user)
    assert_difference 'Dashboard.count', 1 do
      post @base, params: { name: 'Marketing' }, headers: headers
    end
    assert_response :ok
    id = JSON.parse(response.body)['dashboard']['id']

    patch "#{@base}/#{id}", params: { name: 'Marketing EU' }, headers: headers
    assert_response :ok
    assert_equal 'Marketing EU', JSON.parse(response.body)['dashboard']['name']

    assert_difference 'Dashboard.count', -1 do
      delete "#{@base}/#{id}", headers: headers
    end
    assert_response :ok
    assert_equal 'Dashboard deleted', JSON.parse(response.body)['message']
  end

  test 'create rejects a blank name and the project cap' do
    post @base, params: { name: '' }, headers: @headers
    assert_response :unprocessable_entity
    assert_match(/Name/, JSON.parse(response.body)['error'])
    (Dashboard::MAX_PER_PROJECT - @project.dashboards.count).times { |i| @project.dashboards.create!(name: "d#{i}") }
    post @base, params: { name: 'Overflow' }, headers: @headers
    assert_response :unprocessable_entity
  end

  test 'a dashboard from another project is 404' do
    other = dashboards(:two)
    patch "#{@base}/#{other.id}", params: { name: 'x' }, headers: @headers
    assert_response :not_found
    delete "#{@base}/#{other.id}", headers: @headers
    assert_response :not_found
  end

  test 'update with an invalid name persists nothing, including widget_order' do
    a = dashboard_widgets(:installs_by_country)
    b = dashboard_widgets(:total_opens)
    patch "#{@base}/#{@dashboard.id}", params: { name: '', widget_order: [b.id, a.id] }, headers: @headers
    assert_response :unprocessable_entity
    assert_equal 0, a.reload.position
    assert_equal 1, b.reload.position
    assert_equal 'Growth', @dashboard.reload.name
  end

  test 'widget_order reorders widgets and ignores foreign ids' do
    a = dashboard_widgets(:installs_by_country)
    b = dashboard_widgets(:total_opens)
    patch "#{@base}/#{@dashboard.id}", params: { widget_order: [b.id, a.id, 999_999] }, headers: @headers
    assert_response :ok
    assert_equal [b.id, a.id], JSON.parse(response.body)['dashboard']['widgets'].map { |w| w['id'] }
    assert_equal 0, b.reload.position
    assert_equal 1, a.reload.position
  end

  test 'widget_order alone bumps the dashboard updated_at' do
    @dashboard.update_column(:updated_at, 1.day.ago)
    patch "#{@base}/#{@dashboard.id}", params: { widget_order: [dashboard_widgets(:total_opens).id] }, headers: @headers
    assert_response :ok
    assert_in_delta Time.current, @dashboard.reload.updated_at, 1.minute
  end

  test 'widget_order ignores elements that are not ids' do
    a = dashboard_widgets(:installs_by_country)
    b = dashboard_widgets(:total_opens)
    patch "#{@base}/#{@dashboard.id}", params: { widget_order: [{ id: b.id }, [a.id]] }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 0, a.reload.position
    assert_equal 1, b.reload.position
  end

  test 'create widget validates the stored query and appends at the end' do
    body = { title: 'Unique visitors by OS', viz: 'table', size: 'lg',
             query: { metric: 'unique_visitors', group_by: 'os', limit: 5, compare: true },
             filters: [{ field: 'country', operator: 'is', value: 'RO' }] }
    assert_difference 'DashboardWidget.count', 1 do
      post "#{@base}/#{@dashboard.id}/widgets", params: body, headers: @headers, as: :json
    end
    assert_response :ok
    w = JSON.parse(response.body)['widget']
    assert_equal 2, w['position']
    assert_equal({ 'metric' => 'unique_visitors', 'group_by' => 'os', 'limit' => 5, 'compare' => true }, w['query'])
    assert_equal 'RO', w['filters'][0]['value']

    post "#{@base}/#{@dashboard.id}/widgets", params: body.merge(query: { metric: 'revenue' }), headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_match(/Query/, JSON.parse(response.body)['error'])
  end

  test 'create widget keeps array-valued filter values' do
    body = { title: 'Installs', viz: 'number', size: 'sm', query: { metric: 'installs' },
             filters: [{ field: 'country', operator: 'is', value: %w[RO DE] }] }
    post "#{@base}/#{@dashboard.id}/widgets", params: body, headers: @headers, as: :json
    assert_response :ok
    assert_equal %w[RO DE], JSON.parse(response.body)['widget']['filters'][0]['value']
  end

  test 'create panel widget defaults kind to metric and validates the panel name' do
    body = { title: 'Retention', kind: 'panel', panel: 'retention', size: 'sm', query: {}, filters: [] }
    assert_difference 'DashboardWidget.count', 1 do
      post "#{@base}/#{@dashboard.id}/widgets", params: body, headers: @headers, as: :json
    end
    assert_response :ok
    w = JSON.parse(response.body)['widget']
    assert_equal 'panel', w['kind']
    assert_equal 'retention', w['panel']

    get @base, headers: @headers
    listed = JSON.parse(response.body)['dashboards'][0]['widgets'].find { |x| x['id'] == w['id'] }
    assert_equal 'panel', listed['kind']
    assert_equal 'retention', listed['panel']

    post "#{@base}/#{@dashboard.id}/widgets", params: body.merge(panel: 'nope'), headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test 'create user_trends panel widget' do
    body = { title: 'New users trend', kind: 'panel', panel: 'user_trends', size: 'md', query: {}, filters: [] }
    post "#{@base}/#{@dashboard.id}/widgets", params: body, headers: @headers, as: :json
    assert_response :ok
    assert_equal 'user_trends', JSON.parse(response.body)['widget']['panel']
  end

  test 'create KPI row panel widgets' do
    %w[kpis_acquisition kpis_engagement kpis_revenue kpis_links revenue_trend].each do |panel|
      body = { title: panel, kind: 'panel', panel: panel, size: 'lg', query: {}, filters: [] }
      post "#{@base}/#{@dashboard.id}/widgets", params: body, headers: @headers, as: :json
      assert_response :ok
      assert_equal panel, JSON.parse(response.body)['widget']['panel']
    end
  end

  test 'widget subtitle is optional, stored, updatable and capped' do
    body = { title: 'Channels', kind: 'panel', panel: 'acquisition_channels', size: 'md', query: {}, filters: [] }
    post "#{@base}/#{@dashboard.id}/widgets", params: body, headers: @headers, as: :json
    assert_response :ok
    widget = JSON.parse(response.body)['widget']
    assert_nil widget['subtitle']

    patch "#{@base}/#{@dashboard.id}/widgets/#{widget['id']}", params: { subtitle: 'Share of new users' }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 'Share of new users', JSON.parse(response.body)['widget']['subtitle']

    post "#{@base}/#{@dashboard.id}/widgets", params: body.merge(subtitle: 'x' * 141), headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test 'changing a widget bumps the dashboard updated_at' do
    @dashboard.update_columns(updated_at: 2.days.ago)
    delete "#{@base}/#{@dashboard.id}/widgets/#{dashboard_widgets(:total_opens).id}", headers: @headers
    assert_response :ok
    assert_in_delta Time.current, @dashboard.reload.updated_at, 5
  end

  test 'update and delete widget' do
    w = dashboard_widgets(:total_opens)
    patch "#{@base}/#{@dashboard.id}/widgets/#{w.id}", params: { title: 'Opens (iOS)', size: 'lg' }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 'Opens (iOS)', JSON.parse(response.body)['widget']['title']
    assert_equal 'lg', w.reload.size

    assert_difference 'DashboardWidget.count', -1 do
      delete "#{@base}/#{@dashboard.id}/widgets/#{w.id}", headers: @headers
    end
    assert_response :ok
    assert_equal 'Widget deleted', JSON.parse(response.body)['message']
  end

  test 'a widget belonging to a different dashboard is 404, even under a dashboard the caller owns' do
    w = dashboard_widgets(:other_tenant_widget)
    url = "#{@base}/#{@dashboard.id}/widgets/#{w.id}"
    patch url, params: { title: 'x' }, headers: @headers, as: :json
    assert_response :not_found
    delete url, headers: @headers
    assert_response :not_found
  end
end
