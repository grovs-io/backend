require "test_helper"

class SmartBannerStatsWindowAndIsolationTest < ActiveSupport::TestCase
  include ClickhouseTestHelper
  include SmartBannerTestHelper

  fixtures :instances, :projects, :domains, :redirect_configs

  NOW = Time.utc(2026, 10, 21, 12, 0, 0)

  setup do
    skip_unless_clickhouse!
    travel_to NOW
    @project = projects(:one)
    @other_project = projects(:two)
    @banner = create_test_banner(@project, name: "A")
    @tags = Array(@banner.default_link.tags)
  end

  teardown { travel_back }

  test "the window starts at midnight UTC 30 days ago, inclusive" do
    first_day = Time.utc(2026, 9, 21, 0, 0, 0)
    insert_ch_events([
      banner_event("smart_banner_view", at: first_day),
      banner_event("smart_banner_view", at: first_day - 0.001),
      banner_event("smart_banner_click", at: first_day - 0.001),
      link_event("open", at: first_day),
      link_event("install", at: first_day - 0.001)
    ])

    stats = SmartBannerStatsService.for_banners(@project, [@banner])[@banner.id]

    assert_equal [1, 0, 1, 0], stats.values_at("views", "clicks", "opens", "installs")
  end

  test "events of another project carrying the same banner id or tag are not counted" do
    insert_ch_events([
      banner_event("smart_banner_view", project_id: @other_project.id),
      banner_event("smart_banner_click", project_id: @other_project.id),
      link_event("open", project_id: @other_project.id),
      link_event("install", project_id: @other_project.id),
      banner_event("smart_banner_view")
    ])

    assert_equal({ "views" => 1, "clicks" => 0, "dismisses" => 0, "ctr" => 0.0, "opens" => 0, "installs" => 0 },
                 SmartBannerStatsService.for_banners(@project, [@banner])[@banner.id])
  end

  test "only custom banner events and open/install/reinstall link events count" do
    insert_ch_events([
      banner_event("smart_banner_view", event_type: "view"),
      banner_event("smart_banner_impression"),
      link_event(Grovs::Events::VIEW),
      link_event(Grovs::Events::REACTIVATION),
      link_event("reinstall")
    ])

    stats = SmartBannerStatsService.for_banners(@project, [@banner])[@banner.id]

    assert_equal [0, 0, 1], stats.values_at("views", "opens", "installs")
  end

  test "a banner tag without the shared smart_banner tag is not a banner link" do
    insert_ch_events([link_event("open", tags: ["smart_banner:#{@banner.id}"])])

    assert_equal 0, SmartBannerStatsService.for_banners(@project, [@banner])[@banner.id]["opens"]
  end

  test "clicks without views give a zero ctr, and ctr rounds to four places" do
    other = create_test_banner(@project, name: "B")
    insert_ch_events([
      banner_event("smart_banner_click"),
      *Array.new(3) { banner_event("smart_banner_view", banner_id: other.id) },
      *Array.new(2) { banner_event("smart_banner_click", banner_id: other.id) }
    ])

    stats = SmartBannerStatsService.for_banners(@project, [@banner, other])

    assert_equal [0, 1, 0.0], stats[@banner.id].values_at("views", "clicks", "ctr")
    assert_equal 0.6667, stats[other.id]["ctr"]
  end

  test "with ClickHouse reads off every banner gets empty stats without a query" do
    insert_ch_events([banner_event("smart_banner_view")])
    stub_ch_flags(false)
    Clickhouse.stub(:with, ->(*) { flunk "ClickHouse queried with reads disabled" }) do
      assert_equal({ @banner.id => SmartBannerSerializer::EMPTY_STATS },
                   SmartBannerStatsService.for_banners(@project, [@banner]))
    end
  ensure
    unstub_ch_flags
  end

  test "no banners means no query and an empty result" do
    Clickhouse.stub(:with, ->(*) { flunk "ClickHouse queried for no banners" }) do
      assert_equal({}, SmartBannerStatsService.for_banners(@project, []))
    end
  end

  private

  def stamp(time)
    time.utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
  end

  def banner_event(name, banner_id: @banner.id, project_id: @project.id, event_type: "custom", at: 1.day.ago)
    { event_id: "sbw_#{SecureRandom.hex(6)}", project_id: project_id, event_type: event_type, event_name: name,
      properties: { "smart_banner_id" => banner_id }, created_at: stamp(at) }
  end

  def link_event(type, project_id: @project.id, tags: @tags, at: 1.day.ago)
    { event_id: "sbwl_#{SecureRandom.hex(6)}", project_id: project_id, event_type: type,
      link_id: @banner.default_link_id, link_tags: tags, created_at: stamp(at) }
  end
end
