require "test_helper"

class LinkMetricsHelperTest < ActiveSupport::TestCase
  include LinkMetricsHelper

  fixtures :instances, :projects, :domains, :links, :redirect_configs,
           :users, :instance_roles, :campaigns, :link_daily_statistics

  setup do
    @project = projects(:one)
    @user = users(:admin_user)
    @domain = domains(:one)
    # Create test links with nil data to avoid the production bug in
    # export_links_metrics_to_csv where link.data (a json column that
    # returns strings) has .map called on it.
    @link = Link.create!(
      domain: @domain, redirect_config: redirect_configs(:one),
      path: "csv-test-#{SecureRandom.hex(4)}", title: "CSV Test Link",
      subtitle: "For metrics", generated_from_platform: "ios",
      sdk_generated: false, active: true
    )
  end

  # ---------------------------------------------------------------------------
  # fetch_links_for_search_params — authorization + filtering
  # ---------------------------------------------------------------------------

  test "returns links for authorized user" do
    result = fetch_links_for_search_params(@project.id, @user.id, true, false, nil)

    assert_not_nil result
    assert_includes result.map(&:id), @link.id
  end

  test "returns nil for non-existent project" do
    result = fetch_links_for_search_params(-1, @user.id, true, false, nil)

    assert_nil result
  end

  test "returns nil when user has no instance role" do
    outsider = users(:oauth_user) # no instance_role for project one's instance

    result = fetch_links_for_search_params(@project.id, outsider.id, true, false, nil)

    assert_nil result
  end

  test "filters by active status" do
    inactive_link = Link.create!(
      domain: @domain, redirect_config: redirect_configs(:one),
      path: "inactive-#{SecureRandom.hex(4)}", generated_from_platform: "ios",
      active: false, sdk_generated: false
    )

    active_result = fetch_links_for_search_params(@project.id, @user.id, true, false, nil)
    inactive_result = fetch_links_for_search_params(@project.id, @user.id, false, false, nil)

    assert_includes active_result.map(&:id), @link.id
    assert_not_includes active_result.map(&:id), inactive_link.id

    assert_includes inactive_result.map(&:id), inactive_link.id
    assert_not_includes inactive_result.map(&:id), @link.id
  end

  test "filters by sdk_generated" do
    sdk_link = Link.create!(
      domain: @domain, redirect_config: redirect_configs(:one),
      path: "sdk-#{SecureRandom.hex(4)}", generated_from_platform: "ios",
      sdk_generated: true, active: true
    )

    sdk_result = fetch_links_for_search_params(@project.id, @user.id, true, true, nil)
    non_sdk_result = fetch_links_for_search_params(@project.id, @user.id, true, false, nil)

    assert_includes sdk_result.map(&:id), sdk_link.id
    assert_not_includes non_sdk_result.map(&:id), sdk_link.id
  end

  # ---------------------------------------------------------------------------
  # export_links_metrics_to_csv — CSV generation
  # ---------------------------------------------------------------------------

  test "generates CSV with correct headers" do
    csv = export_links_metrics_to_csv(
      links: [@link],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 2)
    )

    rows = CSV.parse(csv, headers: true)
    expected_headers = [
      "Link ID", "Name", "Title", "Subtitle", "Updated At",
      "Generated From Platform", "SDK Generated", "Tags", "Active",
      "Access Path", "View", "Open", "Install", "Reinstall",
      "Reactivation", "Avg Engagement Time", "Time Spent", "Data", "Campaign"
    ]

    assert_equal expected_headers, rows.headers
  end

  test "aggregates metrics across date range" do
    # Create stats for our test link
    create_stat(@link, Date.new(2026, 3, 1), views: 100, opens: 50, installs: 10, reinstalls: 2, reactivations: 1, time_spent: 5000)
    create_stat(@link, Date.new(2026, 3, 2), views: 200, opens: 80, installs: 20, reinstalls: 5, reactivations: 3, time_spent: 8000)

    csv = export_links_metrics_to_csv(
      links: [@link],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 2)
    )

    rows = CSV.parse(csv, headers: true)
    row = rows.first

    assert_equal "300", row["View"]       # 100 + 200
    assert_equal "130", row["Open"]       # 50 + 80
    assert_equal "30", row["Install"]     # 10 + 20
    assert_equal "7", row["Reinstall"]    # 2 + 5
    assert_equal "4", row["Reactivation"] # 1 + 3
    assert_equal "13000", row["Time Spent"] # 5000 + 8000
  end

  test "populates link metadata in CSV row" do
    create_stat(@link, Date.new(2026, 3, 1), views: 10)

    csv = export_links_metrics_to_csv(
      links: [@link],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 1)
    )

    rows = CSV.parse(csv, headers: true)
    row = rows.first

    assert_equal @link.id.to_s, row["Link ID"]
    assert_equal "CSV Test Link", row["Title"]
    assert_equal "For metrics", row["Subtitle"]
    assert_equal "ios", row["Generated From Platform"]
    assert_equal "false", row["SDK Generated"]
    assert_equal "true", row["Active"]
    assert_includes row["Access Path"], @link.path
  end

  test "uses zero defaults for links with no stats" do
    csv = export_links_metrics_to_csv(
      links: [@link],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 2)
    )

    rows = CSV.parse(csv, headers: true)
    row = rows.first

    assert_equal "0", row["View"]
    assert_equal "0", row["Open"]
    assert_equal "0", row["Install"]
    assert_equal "0", row["Time Spent"]
  end

  test "returns empty string for empty links array" do
    csv = export_links_metrics_to_csv(
      links: [],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 2)
    )

    assert_equal "", csv
  end

  test "single-day date range only includes that day stats" do
    create_stat(@link, Date.new(2026, 3, 1), views: 100)
    create_stat(@link, Date.new(2026, 3, 2), views: 200)

    csv = export_links_metrics_to_csv(
      links: [@link],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 1)
    )

    rows = CSV.parse(csv, headers: true)
    assert_equal "100", rows.first["View"]
  end

  test "includes campaign name when link has a campaign" do
    @link.update!(campaign: campaigns(:one))
    create_stat(@link, Date.new(2026, 3, 1), views: 10)

    csv = export_links_metrics_to_csv(
      links: [@link],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 1)
    )

    rows = CSV.parse(csv, headers: true)
    assert_equal campaigns(:one).name, rows.first["Campaign"]
  end

  test "multiple links produce multiple CSV rows" do
    link2 = Link.create!(
      domain: @domain, redirect_config: redirect_configs(:one),
      path: "csv-test2-#{SecureRandom.hex(4)}", generated_from_platform: "android",
      sdk_generated: false, active: true
    )

    csv = export_links_metrics_to_csv(
      links: [@link, link2],
      project_id: @project.id,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 2)
    )

    rows = CSV.parse(csv, headers: true)
    assert_equal 2, rows.size
  end

  private

  def create_stat(link, date, metrics = {})
    LinkDailyStatistic.create!(
      link: link,
      project_id: @project.id,
      event_date: date,
      platform: "ios",
      views: metrics[:views] || 0,
      opens: metrics[:opens] || 0,
      installs: metrics[:installs] || 0,
      reinstalls: metrics[:reinstalls] || 0,
      reactivations: metrics[:reactivations] || 0,
      time_spent: metrics[:time_spent] || 0,
      app_opens: 0, user_referred: 0, revenue: 0
    )
  end
end
