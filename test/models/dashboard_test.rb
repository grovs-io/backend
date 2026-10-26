# frozen_string_literal: true

require 'test_helper'

class DashboardTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :dashboards, :dashboard_widgets

  test 'requires a name within 100 chars' do
    d = Dashboard.new(project: projects(:one), name: '')
    assert_not d.valid?
    d.name = 'x' * 101
    assert_not d.valid?
    d.name = 'Weekly'
    assert d.valid?
  end

  test 'caps dashboards per project' do
    project = projects(:one)
    (Dashboard::MAX_PER_PROJECT - project.dashboards.count).times { |i| project.dashboards.create!(name: "d#{i}") }
    extra = project.dashboards.build(name: 'one too many')
    assert_not extra.valid?
    assert_includes extra.errors[:base].join, 'at most'
  end

  test 'widgets are ordered by position and destroyed with the dashboard' do
    d = dashboards(:one)
    assert_equal %w[installs_by_country total_opens].map { |f| dashboard_widgets(f).id }, d.widgets.map(&:id)
    assert_difference 'DashboardWidget.count', -2 do
      d.destroy!
    end
  end
end
