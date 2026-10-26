# frozen_string_literal: true

require 'test_helper'

class DashboardWidgetTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :dashboards, :dashboard_widgets

  def widget(attrs = {})
    dashboards(:one).widgets.build({ title: 'T', viz: 'bar', size: 'md',
                                     query: { 'metric' => 'installs', 'group_by' => 'country' }, filters: [] }.merge(attrs))
  end

  test 'valid widget canonicalises query keys and defaults' do
    w = widget
    assert w.valid?, w.errors.full_messages.join(', ')
    assert_equal({ 'metric' => 'installs', 'group_by' => 'country', 'limit' => 10, 'compare' => false }, w.query)
  end

  test 'rejects unknown metric, dimension, granularity, viz and size' do
    assert_not widget(query: { 'metric' => 'revenue' }).valid?
    assert_not widget(query: { 'metric' => 'installs', 'group_by' => 'ip' }).valid?
    assert_not widget(query: { 'metric' => 'installs', 'granularity' => 'hour' }).valid?
    assert_not widget(viz: 'pie').valid?
    assert_not widget(size: 'xl').valid?
  end

  test 'drops keys the query contract does not know and keeps granularity/compare/limit' do
    w = widget(query: { 'metric' => 'views', 'granularity' => 'week', 'limit' => '5', 'compare' => 'true', 'start_date' => '2026-01-01', 'junk' => 1 })
    assert w.valid?
    assert_equal({ 'metric' => 'views', 'granularity' => 'week', 'limit' => 5, 'compare' => true }, w.query)
  end

  test 'filters must be an array of explorer chips' do
    assert widget(filters: [{ 'field' => 'country', 'operator' => 'is', 'value' => 'RO' }]).valid?
    assert_not widget(filters: { 'field' => 'country' }).valid?
    assert_not widget(filters: [{ 'field' => 'country', 'operator' => 'gt', 'value' => 'RO' }]).valid?
    assert_not widget(filters: Array.new(26) { { 'field' => 'country', 'operator' => 'is', 'value' => 'RO' } }).valid?

    w = widget(filters: Array.new(26) { { 'field' => 'country', 'operator' => 'is', 'value' => 'RO', 'extra' => 1 } })
    assert_not w.valid?
    assert_equal 26, w.filters.size
    assert w.filters.first.key?('extra'), 'an invalid record must not be canonicalised'
  end

  test 'caps filter field and value sizes' do
    chip = ->(field: 'country', value: 'RO') { [{ 'field' => field, 'operator' => 'is', 'value' => value }] }
    assert widget(filters: chip.call(value: 'a' * 200)).valid?
    assert widget(filters: chip.call(value: Array.new(50) { 'a' * 200 })).valid?
    assert widget(filters: chip.call(field: 'user.plan', value: '42')).valid?

    w = widget(filters: chip.call(value: 'a' * 201))
    assert_not w.valid?
    assert_includes w.errors[:filters], 'filter values must be strings of at most 200 characters, at most 50 per filter'
    assert_not widget(filters: chip.call(value: Array.new(51) { 'a' })).valid?
    assert_not widget(filters: chip.call(value: ['a' * 201])).valid?
    assert_not widget(filters: chip.call(value: [{ 'x' => 1 }])).valid?
    assert_not widget(filters: chip.call(value: { 'x' => 1 })).valid?
    assert_not widget(filters: chip.call(field: "user.#{'k' * 100}")).valid?
  end

  test 'rejects a chip that produces no SQL and still allows a valid one' do
    w = widget(filters: [{ 'field' => 'link_id', 'operator' => 'contains', 'value' => '123' }])
    assert_not w.valid?
    assert_includes w.errors[:filters], 'filters contain an unsupported filter: link_id contains'

    assert widget(filters: [{ 'field' => 'country', 'operator' => 'is', 'value' => 'RO' }]).valid?
    assert widget(filters: [{ 'field' => 'platform', 'operator' => 'is', 'value' => 'ios' }]).valid?
    assert widget(filters: [{ 'field' => 'country', 'operator' => 'is', 'value' => %w[RO FR] }]).valid?
  end

  test 'panel widgets need a known panel and an empty query' do
    w = widget(kind: 'panel', panel: 'retention', query: {})
    assert w.valid?, w.errors.full_messages.join(', ')
    assert_not widget(kind: 'panel', panel: 'nope', query: {}).valid?
    assert_not widget(kind: 'panel', panel: 'retention', query: { 'metric' => 'installs' }).valid?
    assert_not widget(kind: 'metric', panel: 'retention').valid?
    assert_not widget(kind: 'bogus').valid?
  end

  test 'user_trends is a known panel' do
    w = widget(kind: 'panel', panel: 'user_trends', query: {})
    assert w.valid?, w.errors.full_messages.join(', ')
  end

  test 'KPI row panels are known panels' do
    %w[kpis_acquisition kpis_engagement kpis_revenue kpis_links revenue_trend].each do |panel|
      w = widget(kind: 'panel', panel: panel, query: {})
      assert w.valid?, "#{panel}: #{w.errors.full_messages.join(', ')}"
    end
  end

  test 'caps widgets per dashboard' do
    d = dashboards(:one)
    (DashboardWidget::MAX_PER_DASHBOARD - d.widgets.count).times { |i| widget(title: "w#{i}").save! }
    assert_not widget(title: 'over').valid?
  end

  test 'serializer exposes the stored shape' do
    h = DashboardWidgetSerializer.serialize(dashboard_widgets(:total_opens))
    assert_equal 'number', h['viz']
    assert_equal 'ios', h['filters'][0]['value']
    assert_equal 'metric', h['kind']
    assert_nil h['panel']
    d = DashboardSerializer.serialize(dashboards(:one))
    assert_equal 2, d['widgets'].size
    assert_equal 'Installs by country', d['widgets'][0]['title']

    panel = DashboardWidgetSerializer.serialize(dashboard_widgets(:retention_panel))
    assert_equal 'panel', panel['kind']
    assert_equal 'retention', panel['panel']
  end
end
