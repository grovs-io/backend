# frozen_string_literal: true

require 'test_helper'
require_relative 'auth_test_helper'

class DashboardsIsolationAndOrderingTest < ActionDispatch::IntegrationTest
  include AuthTestHelper

  fixtures :instances, :users, :instance_roles, :projects, :dashboards, :dashboard_widgets

  setup do
    @project = projects(:one)
    @dashboard = dashboards(:one)
    @headers = doorkeeper_headers_for(users(:member_user))
    @base = "#{API_PREFIX}/projects/#{@project.id}/dashboards"
    @a = dashboard_widgets(:installs_by_country)
    @b = dashboard_widgets(:total_opens)
  end

  def widget_body(title = 'W')
    { title: title, viz: 'number', size: 'sm', query: { metric: 'installs' }, filters: [] }
  end

  def json
    JSON.parse(response.body)
  end

  test "widget routes under another project's dashboard are 404 and touch nothing" do
    foreign = dashboards(:two)
    foreign_widget = dashboard_widgets(:other_tenant_widget)
    assert_no_difference -> { DashboardWidget.count } do
      post "#{@base}/#{foreign.id}/widgets", params: widget_body, headers: @headers, as: :json
      assert_response :not_found
      assert_equal({ 'error' => 'Dashboard not found' }, json)
      patch "#{@base}/#{foreign.id}/widgets/#{foreign_widget.id}", params: { title: 'pwned' }, headers: @headers, as: :json
      assert_response :not_found
      delete "#{@base}/#{foreign.id}/widgets/#{foreign_widget.id}", headers: @headers
      assert_response :not_found
    end
    assert_equal 'Other tenant widget', foreign_widget.reload.title
  end

  test 'a missing widget id under an owned dashboard is 404 with the widget error' do
    patch "#{@base}/#{@dashboard.id}/widgets/0", params: { title: 'x' }, headers: @headers, as: :json
    assert_response :not_found
    assert_equal({ 'error' => 'Widget not found' }, json)
  end

  test 'every dashboard mutation on a project outside the caller instance is forbidden' do
    other = projects(:two)
    foreign_base = "#{API_PREFIX}/projects/#{other.id}/dashboards"
    d = dashboards(:two)
    w = dashboard_widgets(:other_tenant_widget)
    assert_no_difference ['Dashboard.count', 'DashboardWidget.count'] do
      post foreign_base, params: { name: 'x' }, headers: @headers, as: :json
      assert_response :forbidden
      patch "#{foreign_base}/#{d.id}", params: { name: 'x' }, headers: @headers, as: :json
      assert_response :forbidden
      delete "#{foreign_base}/#{d.id}", headers: @headers
      assert_response :forbidden
      post "#{foreign_base}/#{d.id}/widgets", params: widget_body, headers: @headers, as: :json
      assert_response :forbidden
      delete "#{foreign_base}/#{d.id}/widgets/#{w.id}", headers: @headers
      assert_response :forbidden
    end
    assert_equal 'Other tenant', d.reload.name
  end

  test 'widget_order counts duplicates once and appends unlisted widgets in their current order' do
    c = @dashboard.widgets.create!(widget_body('C').merge(position: 2))
    patch "#{@base}/#{@dashboard.id}", params: { widget_order: [@b.id, @b.id] }, headers: @headers, as: :json
    assert_response :ok
    assert_equal [@b.id, @a.id, c.id], json['dashboard']['widgets'].map { |w| w['id'] }
    assert_equal [0, 1, 2], [@b, @a, c].map { |w| w.reload.position }

    patch "#{@base}/#{@dashboard.id}", params: { widget_order: [c.id.to_s, @a.id.to_s] }, headers: @headers, as: :json
    assert_response :ok
    assert_equal [c.id, @a.id, @b.id], json['dashboard']['widgets'].map { |w| w['id'] }
    assert_equal 'Growth', @dashboard.reload.name, 'a reorder without name keeps the name'
  end

  test 'an invalid widget update returns the validation error and persists nothing' do
    stored = @b.query
    patch "#{@base}/#{@dashboard.id}/widgets/#{@b.id}", params: { query: { metric: 'revenue' } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Query metric must be one of #{Analytics::MetricQuery::METRICS.join(', ')}", json['error']
    assert_equal stored, @b.reload.query

    patch "#{@base}/#{@dashboard.id}/widgets/#{@b.id}", params: { title: '' }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Title can't be blank", json['error']
    assert_equal 'Opens', @b.reload.title
  end

  test 'patching only the title keeps the stored query and filters' do
    query = @b.query
    filters = @b.filters
    patch "#{@base}/#{@dashboard.id}/widgets/#{@b.id}", params: { title: 'Opens (all)' }, headers: @headers, as: :json
    assert_response :ok
    @b.reload
    assert_equal 'Opens (all)', @b.title
    assert_equal query, @b.query
    assert_equal filters, @b.filters
  end

  test 'a full dashboard rejects a new widget with the cap message yet its widgets stay editable' do
    (DashboardWidget::MAX_PER_DASHBOARD - @dashboard.widgets.count).times { |i| @dashboard.widgets.create!(widget_body("f#{i}")) }
    assert_no_difference -> { DashboardWidget.count } do
      post "#{@base}/#{@dashboard.id}/widgets", params: widget_body('over'), headers: @headers, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal 'a dashboard can have at most 20 widgets', json['error']

    patch "#{@base}/#{@dashboard.id}/widgets/#{@a.id}", params: { size: 'lg' }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 'lg', @a.reload.size
  end

  test 'new dashboards append after existing ones and a full project can still rename' do
    post @base, params: { name: 'Second' }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 1, json['dashboard']['position']
    assert_equal [], json['dashboard']['widgets']

    (Dashboard::MAX_PER_PROJECT - @project.dashboards.count).times { |i| @project.dashboards.create!(name: "d#{i}", position: 2 + i) }
    post @base, params: { name: 'Overflow' }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal 'a project can have at most 10 dashboards', json['error']

    patch "#{@base}/#{@dashboard.id}", params: { name: 'Growth v2' }, headers: @headers, as: :json
    assert_response :ok
    get @base, headers: @headers
    names = json['dashboards'].map { |d| d['name'] }
    assert_equal ['Growth v2', 'Second'], names.first(2)
    assert_equal 10, names.size
  end

  test 'deleting a dashboard deletes its widgets and leaves other dashboards alone' do
    ids = @dashboard.widgets.pluck(:id)
    assert_equal 2, ids.size
    delete "#{@base}/#{@dashboard.id}", headers: @headers
    assert_response :ok
    assert_equal 0, DashboardWidget.where(id: ids).count
    assert DashboardWidget.exists?(dashboard_widgets(:other_tenant_widget).id)
  end
end
